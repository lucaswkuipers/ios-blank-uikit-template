import profile from "./request.mobileconfig"

const statuses = ["pending", "waiting", "approved", "preparing", "ready", "failed", "declined", "removed"]
const baseHeaders = { "cache-control": "no-store", "x-content-type-options": "nosniff" }

function json(value, status) {
  return new Response(JSON.stringify(value), { status, headers: { ...baseHeaders, "content-type": "application/json" } })
}

function authorized(request, env) {
  if (typeof env.ADMIN_TOKEN !== "string" || env.ADMIN_TOKEN.length < 32) {
    return false
  }
  const expected = new TextEncoder().encode(`Bearer ${env.ADMIN_TOKEN}`)
  const actual = new TextEncoder().encode(request.headers.get("authorization") ?? "")
  return expected.length === actual.length && crypto.subtle.timingSafeEqual(expected, actual)
}

function attribute(plist, key) {
  const match = plist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`))
  if (!match) {
    return ""
  }
  return match[1].replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&quot;", "\"").replaceAll("&apos;", "'").replaceAll("&amp;", "&")
}

function clean(text, limit) {
  return text.replace(/[\u0000-\u001F\u007F-\u009F‎‏‪-‮⁦-⁩]/g, "").trim().slice(0, limit)
}

function back(request, query) {
  return Response.redirect(`${new URL(request.url).origin}/?${query}`, 301)
}

async function body(request) {
  try {
    const value = await request.json()
    return value !== null && typeof value === "object" ? value : {}
  } catch {
    return {}
  }
}

async function enroll(request, env) {
  const text = new TextDecoder().decode(await request.arrayBuffer())
  const start = text.indexOf("<?xml")
  const end = text.indexOf("</plist>")
  const plist = start >= 0 && end > start ? text.slice(start, end) : ""
  const udid = attribute(plist, "UDID").trim()
  if (!/^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$/.test(udid)) {
    return back(request, "error=device")
  }
  const model = clean(attribute(plist, "PRODUCT"), 40)
  if (!/^(iPhone|iPad|iPod)/.test(model)) {
    return back(request, "error=iphone")
  }
  const deviceName = clean(attribute(plist, "DEVICE_NAME"), 50) || "iPhone"
  const systemVersion = clean(attribute(plist, "VERSION"), 20)
  const now = new Date().toISOString()
  const recent = new Date(Date.now() - 7 * 86400000).toISOString()
  await env.DB.prepare(`INSERT OR IGNORE INTO requests (id, udid, device_name, model, system_version, status, created_at, updated_at)
    SELECT ?, ?, ?, ?, ?, 'pending', ?, ? WHERE (SELECT COUNT(*) FROM requests WHERE status IN ('pending', 'waiting') AND created_at > ?) < 20`)
    .bind(crypto.randomUUID(), udid, deviceName, model, systemVersion, now, now, recent).run()
  const open = await env.DB.prepare("SELECT id FROM requests WHERE udid = ? AND status IN ('pending', 'waiting')").bind(udid).first()
  if (!open) {
    return back(request, "error=busy")
  }
  return back(request, `request=${open.id}`)
}

async function requestStatus(id, env) {
  const row = await env.DB.prepare("SELECT status FROM requests WHERE id = ?").bind(id).first()
  if (!row) {
    return json({ status: "unknown" }, 404)
  }
  if (row.status !== "ready") {
    return json({ status: row.status, install: null }, 200)
  }
  const setting = await env.DB.prepare("SELECT value FROM settings WHERE key = 'install'").first()
  return json({ status: row.status, install: setting ? setting.value : env.INSTALL_LINK }, 200)
}

async function administer(request, env, path) {
  if (!authorized(request, env)) {
    return json({ error: "unauthorized" }, 401)
  }
  if (request.method === "GET" && path === "/admin/requests") {
    const { results } = await env.DB.prepare("SELECT id, udid, device_name AS deviceName, model, system_version AS systemVersion, status FROM requests WHERE status = 'pending' ORDER BY created_at").all()
    return json(results, 200)
  }
  const match = path.match(/^\/admin\/requests\/([0-9a-f-]{36})$/)
  if (request.method === "POST" && match) {
    const { status } = await body(request)
    if (!statuses.includes(status)) {
      return json({ error: "invalid status" }, 400)
    }
    const result = await env.DB.prepare("UPDATE requests SET status = ?, updated_at = ? WHERE id = ?").bind(status, new Date().toISOString(), match[1]).run()
    return json({ updated: result.meta.changes }, result.meta.changes === 1 ? 200 : 404)
  }
  if (request.method === "POST" && path === "/admin/install") {
    const { link } = await body(request)
    if (typeof link !== "string" || typeof env.INSTALL_PREFIX !== "string" || !link.startsWith(env.INSTALL_PREFIX) || !link.endsWith("/AppShelf.plist")) {
      return json({ error: "invalid install link" }, 400)
    }
    await env.DB.prepare("INSERT INTO settings (key, value) VALUES ('install', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").bind(link).run()
    return json({ updated: 1 }, 200)
  }
  return json({ error: "not found" }, 404)
}

function page(env) {
  const owner = JSON.stringify(env.OWNER_NAME).replaceAll("<", "\\u003c")
  const minimum = JSON.stringify(env.MINIMUM_SYSTEM || "").replaceAll("<", "\\u003c")
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>AppShelf</title>
<style>
  :root { --background: #f2f2f7; --card: #ffffff; --text: #1c1c1e; --secondary: #6c6c70; --accent: #007aff; }
  @media (prefers-color-scheme: dark) { :root { --background: #000000; --card: #1c1c1e; --text: #f2f2f7; --secondary: #98989f; --accent: #0a84ff; } }
  [hidden] { display: none !important; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--background); color: var(--text); font: 17px/1.4 -apple-system, system-ui, sans-serif; }
  main { box-sizing: border-box; width: calc(100% - 32px); max-width: 420px; margin: 24px 16px; padding: 32px 24px; border-radius: 24px; background: var(--card); text-align: center; }
  h1 { margin: 0 0 12px; font-size: 28px; }
  p { margin: 0; }
  a { display: block; margin-top: 24px; padding: 16px; border-radius: 14px; background: var(--accent); color: #ffffff; font-weight: 600; text-decoration: none; }
  small { display: block; margin-top: 16px; color: var(--secondary); font-size: 15px; }
</style>
</head>
<body>
<main>
  <h1>AppShelf</h1>
  <p id="message"></p>
  <a id="action" hidden></a>
  <small id="note"></small>
</main>
<script>
  const owner = ${owner}
  const minimum = ${minimum}
  const requirement = minimum ? " AppShelf needs iOS " + minimum + " or later." : ""
  const message = document.getElementById("message")
  const action = document.getElementById("action")
  const note = document.getElementById("note")
  const parameters = new URLSearchParams(location.search)
  const failure = parameters.get("error")
  let request = parameters.get("request")
  try {
    if (request) {
      localStorage.setItem("request", request)
    } else {
      request = localStorage.getItem("request")
    }
  } catch {}
  if (parameters.has("request") || parameters.has("error")) {
    history.replaceState(null, "", "/")
  }
  const agent = navigator.userAgent
  const onDevice = /iPhone|iPad|iPod/.test(agent) || (/Macintosh/.test(agent) && navigator.maxTouchPoints > 1)
  const inSafari = onDevice && !/CriOS|FxiOS|EdgiOS|OPiOS|GSA|FBAN|FBAV|Instagram/.test(agent)

  function show(text, details, link, label) {
    message.textContent = text
    note.textContent = details
    action.hidden = !link
    if (link) {
      action.href = link
      action.textContent = label
    }
  }

  function offerRequest(text, label) {
    if (!onDevice) {
      show("Open this link on your iPhone.", "AppShelf installs " + owner + "'s apps on the iPhone that opens this page.")
    } else if (!inSafari) {
      show("Open this link in Safari.", "Copy the link and paste it into Safari. Other browsers cannot request access or install apps.")
    } else {
      show(text, "Tap " + label + ", then Allow. Open Settings, tap Profile Downloaded, and install it. It only shares this iPhone's device ID with " + owner + " and removes itself right away." + requirement, "/request.mobileconfig", label)
    }
  }

  function forget() {
    try {
      localStorage.removeItem("request")
    } catch {}
    request = null
  }

  async function refresh() {
    if (failure === "busy") {
      show("Too many requests are waiting.", owner + " has too many open requests right now. Try again later.")
      return
    }
    if (failure) {
      offerRequest("This page only works on an iPhone or iPad.", "Request access")
      return
    }
    if (!request) {
      offerRequest("Get " + owner + "'s apps on this iPhone.", "Request access")
      return
    }
    let state
    try {
      const response = await fetch("/status/" + request, { cache: "no-store" })
      state = await response.json()
    } catch {
      show("Can't reach AppShelf right now.", "This page tries again automatically.")
      setTimeout(refresh, 15000)
      return
    }
    switch (state.status) {
    case "pending":
    case "waiting":
      show("Request sent. " + owner + " has been notified.", "This page updates once you're approved. You can also close it and open the link again later.")
      break
    case "approved":
    case "preparing":
      show(owner + " approved this iPhone.", "Preparing AppShelf for this iPhone. This takes a few minutes.")
      break
    case "failed":
      show(owner + " approved this iPhone, but setup did not finish yet.", owner + " can see the problem and will try again. This page updates when it's ready.")
      setTimeout(refresh, 30000)
      return
    case "ready":
      show("This iPhone is approved.", "Install AppShelf, open it, allow notifications, and install apps. Some apps can take a few more minutes before they install." + requirement, state.install, "Install AppShelf")
      return
    case "declined":
      forget()
      offerRequest(owner + " declined this request.", "Request again")
      return
    case "removed":
      forget()
      offerRequest(owner + " removed this iPhone from AppShelf.", "Request again")
      return
    default:
      forget()
      offerRequest("Get " + owner + "'s apps on this iPhone.", "Request access")
      return
    }
    setTimeout(refresh, 10000)
  }

  refresh()
</script>
</body>
</html>`
  return new Response(html, {
    headers: {
      ...baseHeaders,
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }
  })
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (url.pathname.startsWith("/admin/")) {
      return administer(request, env, url.pathname)
    }
    if (request.method === "POST" && url.pathname === "/enroll") {
      return enroll(request, env)
    }
    if (request.method === "GET" && url.pathname === "/request.mobileconfig") {
      return new Response(profile, { headers: { ...baseHeaders, "content-type": "application/x-apple-aspen-config" } })
    }
    const status = url.pathname.match(/^\/status\/([0-9a-f-]{36})$/)
    if (request.method === "GET" && status) {
      return requestStatus(status[1], env)
    }
    if (request.method === "GET" && url.pathname === "/") {
      return page(env)
    }
    return new Response("Not found", { status: 404, headers: baseHeaders })
  }
}
