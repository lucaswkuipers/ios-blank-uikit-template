const headers = {
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff"
}

function failure(message, status) {
  return new Response(message, { status, headers })
}

function decode(encoded) {
  const base64 = encoded.replaceAll("-", "+").replaceAll("_", "/")
  const bytes = Uint8Array.from(atob(base64), character => character.charCodeAt(0))
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes))
}

function escape(value) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&apos;")
}

function downloadURL(location) {
  try {
    const url = new URL(location)
    const token = url.searchParams.get("jwt")?.split(".")
    if (url.protocol !== "https:" || url.hostname !== "release-assets.githubusercontent.com" || url.port || url.username || url.password || url.hash || token?.length !== 3) {
      return null
    }
    const expiration = Math.min(Date.parse(url.searchParams.get("se")), decode(token[1]).exp * 1000)
    return expiration > Date.now() + 60000 ? url.href : null
  } catch {
    return null
  }
}

export async function download(request, env) {
  const url = new URL(request.url)
  const match = url.pathname.match(/^\/download\/([A-Za-z0-9_-]{1,2048})\/([0-9a-f]{64})\/(manifest\.plist|package\.ipa)$/)
  if (!match || url.search) {
    return failure("Not found", 404)
  }
  if (request.method !== "GET" && request.method !== "HEAD") {
    return failure("Method not allowed", 405)
  }
  if (typeof env.ARTIFACT_TOKEN !== "string" || !env.ARTIFACT_TOKEN.startsWith("github_pat_")) {
    return failure("Downloads are not configured yet. Try again shortly.", 503)
  }
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.ARTIFACT_TOKEN), { name: "HMAC", hash: "SHA-256" }, false, ["verify"])
  const signature = Uint8Array.from(match[2].match(/../g), value => parseInt(value, 16))
  const valid = await crypto.subtle.verify("HMAC", key, signature, new TextEncoder().encode(`AppShelf install v1\n${match[1]}`))
  if (!valid) {
    return failure("This install link is not valid. Open AppShelf and try again.", 403)
  }
  let ticket
  try {
    ticket = decode(match[1])
  } catch {
    return failure("Invalid install link", 400)
  }
  if (!ticket || !Number.isSafeInteger(ticket.assetID) || ticket.assetID <= 0
      || typeof ticket.bundleIdentifier !== "string" || !/^com\.lucaswkuipers\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/.test(ticket.bundleIdentifier)
      || typeof ticket.build !== "string" || !/^[0-9]{1,10}(?:\.[0-9]{1,10}){0,2}$/.test(ticket.build)
      || typeof ticket.name !== "string" || !/^[^\u0000-\u001f\u007f\ufffe\uffff]{1,150}$/u.test(ticket.name)
      || !Number.isSafeInteger(ticket.expires)) {
    return failure("Invalid install link", 400)
  }
  const remaining = ticket.expires * 1000 - Date.now()
  if (remaining <= 0 || remaining > 3690000) {
    return failure("This install link has expired. Open AppShelf and tap Install again.", 410)
  }
  if (match[3] === "manifest.plist") {
    const packageURL = new URL("package.ipa", url).href
    const manifest = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${escape(packageURL)}</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>${escape(ticket.bundleIdentifier)}</string><key>bundle-version</key><string>${escape(ticket.build)}</string><key>kind</key><string>software</string><key>title</key><string>${escape(ticket.name)}</string></dict>
</dict></array></dict></plist>`
    return new Response(request.method === "HEAD" ? null : manifest, { headers: { ...headers, "content-type": "application/xml; charset=utf-8" } })
  }
  try {
    const upstreamHeaders = {
      "accept": "application/octet-stream",
      "authorization": `Bearer ${env.ARTIFACT_TOKEN}`,
      "user-agent": "AppShelf",
      "x-github-api-version": "2022-11-28"
    }
    const range = request.headers.get("range")
    if (range) {
      if (!/^bytes=(?:\d+-\d*|-\d+)$/.test(range)) {
        return failure("Invalid download range", 416)
      }
      upstreamHeaders.range = range
    }
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 20000)
    let response
    try {
      response = await fetch(`https://api.github.com/repos/lucaswkuipers/AppShelf-builds/releases/assets/${ticket.assetID}?refresh=${crypto.randomUUID()}`, {
        headers: upstreamHeaders,
        redirect: "manual",
        signal: controller.signal
      })
    } finally {
      clearTimeout(timeout)
    }
    if (response.status === 302) {
      const location = downloadURL(response.headers.get("location"))
      await response.body?.cancel()
      return location ? new Response(null, { status: 302, headers: { ...headers, location } })
        : failure("The package link is unavailable. Try again shortly.", 502)
    }
    if (response.status !== 200 && response.status !== 206) {
      await response.body?.cancel()
      return failure("The package could not be downloaded. Open AppShelf and try again.", response.status === 404 ? 404 : 502)
    }
    const streamedHeaders = new Headers({ ...headers, "content-type": "application/octet-stream" })
    for (const name of ["content-length", "content-range", "accept-ranges", "etag"]) {
      const value = response.headers.get(name)
      if (value !== null) {
        streamedHeaders.set(name, value)
      }
    }
    if (request.method === "HEAD") {
      await response.body?.cancel()
    }
    return new Response(request.method === "HEAD" ? null : response.body, { status: response.status, headers: streamedHeaders })
  } catch {
    return failure("The download service could not reach GitHub. Try again shortly.", 502)
  }
}
