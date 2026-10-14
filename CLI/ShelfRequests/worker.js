import profile from "./request.mobileconfig"

const statuses = ["pending", "waiting", "approved", "preparing", "ready", "failed", "declined", "removed"]
const inviteToken = /^[0-9a-f]{32}$/
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

function supported(env, version) {
  const minimum = parseInt((env.MINIMUM_SYSTEM || "").split(".")[0], 10)
  const build = parseInt(version, 10)
  return !(minimum >= 26 && build > 0) || build >= minimum - 3
}

async function body(request) {
  try {
    const value = await request.json()
    return value !== null && typeof value === "object" ? value : {}
  } catch {
    return {}
  }
}

async function claim(env, invite, device, now) {
  const row = await env.DB.prepare("SELECT request FROM invites WHERE token = ?").bind(invite).first()
  if (!row) {
    return false
  }
  if (row.request) {
    const used = await env.DB.prepare("SELECT udid FROM requests WHERE id = ?").bind(row.request).first()
    return used !== null && used.udid.toLowerCase() === device.udid.toLowerCase()
  }
  const open = await env.DB.prepare("SELECT id FROM requests WHERE udid = ? AND status IN ('pending', 'waiting')").bind(device.udid).first()
  const id = open ? open.id : crypto.randomUUID()
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO requests (id, udid, device_name, model, system_version, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)")
      .bind(id, device.udid, device.name, device.model, device.systemVersion, now, now),
    env.DB.prepare("UPDATE requests SET status = 'pending', updated_at = ? WHERE id = ? AND status = 'waiting'").bind(now, id),
    env.DB.prepare("UPDATE invites SET request = ? WHERE token = ? AND request IS NULL AND EXISTS (SELECT 1 FROM requests WHERE id = ?)").bind(id, invite, id)
  ])
  const claimed = await env.DB.prepare("SELECT request FROM invites WHERE token = ?").bind(invite).first()
  return claimed !== null && claimed.request === id
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
  const device = { udid, model, name: clean(attribute(plist, "DEVICE_NAME"), 50) || "iPhone", systemVersion: clean(attribute(plist, "VERSION"), 20) }
  const now = new Date().toISOString()
  const invite = new URL(request.url).searchParams.get("invite") ?? ""
  if (!supported(env, device.systemVersion)) {
    return back(request, inviteToken.test(invite) ? `invite=${invite}&error=system` : "error=system")
  }
  if (inviteToken.test(invite) && await claim(env, invite, device, now)) {
    return back(request, `invite=${invite}`)
  }
  const recent = new Date(Date.now() - 7 * 86400000).toISOString()
  await env.DB.prepare(`INSERT OR IGNORE INTO requests (id, udid, device_name, model, system_version, status, created_at, updated_at)
    SELECT ?, ?, ?, ?, ?, 'pending', ?, ? WHERE (SELECT COUNT(*) FROM requests WHERE status IN ('pending', 'waiting') AND created_at > ?) < 20`)
    .bind(crypto.randomUUID(), udid, device.name, model, device.systemVersion, now, now, recent).run()
  const open = await env.DB.prepare("SELECT id FROM requests WHERE udid = ? AND status IN ('pending', 'waiting')").bind(udid).first()
  if (!open) {
    return back(request, "error=busy")
  }
  return back(request, `request=${open.id}`)
}

async function state(id, env) {
  const row = await env.DB.prepare("SELECT status FROM requests WHERE id = ?").bind(id).first()
  if (!row) {
    return null
  }
  if (row.status !== "ready") {
    return { status: row.status, install: null }
  }
  const setting = await env.DB.prepare("SELECT value FROM settings WHERE key = 'install'").first()
  return { status: row.status, install: setting ? setting.value : env.INSTALL_LINK, request: id }
}

async function requestStatus(id, env) {
  const current = await state(id, env)
  return current ? json(current, 200) : json({ status: "unknown" }, 404)
}

async function inviteStatus(invite, env) {
  const row = await env.DB.prepare("SELECT name, request FROM invites WHERE token = ?").bind(invite).first()
  if (!row) {
    const cancelled = await env.DB.prepare("SELECT token FROM cancelled_invites WHERE token = ?").bind(invite).first()
    return json({ status: cancelled ? "cancelled" : "unknown" }, 404)
  }
  const current = row.request ? await state(row.request, env) : null
  return json({ status: "invited", install: null, ...current, name: row.name }, 200)
}

async function inviteProfile(invite, request, env) {
  const row = await env.DB.prepare("SELECT profile FROM invites WHERE token = ? AND request IS NULL").bind(invite).first()
  if (!row) {
    return Response.redirect(`${new URL(request.url).origin}/?invite=${invite}`, 302)
  }
  const bytes = Uint8Array.from(atob(row.profile), character => character.charCodeAt(0))
  return new Response(bytes, { headers: { ...baseHeaders, "content-type": "application/x-apple-aspen-config" } })
}

async function administer(request, env, path) {
  if (!authorized(request, env)) {
    return json({ error: "unauthorized" }, 401)
  }
  if (request.method === "GET" && path === "/admin/requests") {
    const { results } = await env.DB.prepare(`SELECT requests.id, requests.udid, requests.device_name AS deviceName, requests.model, requests.system_version AS systemVersion, requests.status, invites.token AS invite
      FROM requests LEFT JOIN invites ON invites.request = requests.id WHERE requests.status = 'pending' ORDER BY requests.created_at`).all()
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
  if (request.method === "GET" && path === "/admin/invites") {
    const { results } = await env.DB.prepare("SELECT token, request FROM invites ORDER BY created_at").all()
    return json(results, 200)
  }
  if (request.method === "POST" && path === "/admin/invites") {
    const { token, name, profile: encoded } = await body(request)
    const display = typeof name === "string" ? clean(name, 50) : ""
    if (typeof token !== "string" || !inviteToken.test(token) || !display || typeof encoded !== "string" || encoded.length > 65536 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
      return json({ error: "invalid invite" }, 400)
    }
    const result = await env.DB.prepare("INSERT OR IGNORE INTO invites (token, name, profile, request, created_at) VALUES (?, ?, ?, NULL, ?)").bind(token, display, encoded, new Date().toISOString()).run()
    return json({ updated: result.meta.changes }, 200)
  }
  if (request.method === "POST" && path === "/admin/invites/remove") {
    const { token } = await body(request)
    if (typeof token !== "string" || !inviteToken.test(token)) {
      return json({ error: "invalid invite" }, 400)
    }
    const results = await env.DB.batch([
      env.DB.prepare("INSERT OR IGNORE INTO cancelled_invites (token, cancelled_at) SELECT token, ? FROM invites WHERE token = ? AND request IS NULL").bind(new Date().toISOString(), token),
      env.DB.prepare("DELETE FROM invites WHERE token = ? AND request IS NULL").bind(token)
    ])
    return json({ updated: results[1].meta.changes }, 200)
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
  ol { margin: 20px 0 0; padding-left: 24px; text-align: left; }
  li { margin-top: 8px; }
  a { display: block; margin-top: 24px; padding: 16px; border-radius: 14px; background: var(--accent); color: #ffffff; font-weight: 600; text-decoration: none; }
  a.secondary { margin-top: 12px; background: transparent; color: var(--accent); border: 2px solid var(--accent); }
  small { display: block; margin-top: 16px; color: var(--secondary); font-size: 15px; }
</style>
</head>
<body>
<main>
  <h1>AppShelf</h1>
  <p id="message"></p>
  <ol id="steps" hidden></ol>
  <a id="action" hidden></a>
  <a id="opener" class="secondary" hidden>Open AppShelf</a>
  <small id="note"></small>
</main>
<script>
  const owner = ${owner}
  const minimum = ${minimum}
  const requirement = minimum ? " AppShelf needs iOS " + minimum + " or later." : ""
  const message = document.getElementById("message")
  const steps = document.getElementById("steps")
  const action = document.getElementById("action")
  const opener = document.getElementById("opener")
  const note = document.getElementById("note")
  const parameters = new URLSearchParams(location.search)
  const failure = parameters.get("error")
  const invite = /^[0-9a-f]{32}$/.test(parameters.get("invite") ?? "") ? parameters.get("invite") : null
  const opened = Date.now()
  let shown = ""
  let timer = null
  let settingUp = null
  let request = parameters.get("request")
  try {
    if (request) {
      localStorage.setItem("request", request)
    } else {
      request = localStorage.getItem("request")
    }
  } catch {}
  if (invite && parameters.has("error")) {
    history.replaceState(null, "", "/?invite=" + invite)
  } else if (!invite && (parameters.has("request") || parameters.has("error"))) {
    history.replaceState(null, "", "/")
  }
  const agent = navigator.userAgent
  const onDevice = /iPhone|iPad|iPod/.test(agent) || (/Macintosh/.test(agent) && navigator.maxTouchPoints > 1)
  const inSafari = onDevice && !/CriOS|FxiOS|EdgiOS|OPiOS|GSA|FBAN|FBAV|Instagram/.test(agent)

  function show(text, details, link, label, instructions) {
    const next = JSON.stringify([text, details, link, label, instructions])
    if (next === shown) {
      return
    }
    shown = next
    opener.hidden = true
    message.textContent = text
    note.textContent = details
    action.hidden = !link
    if (link) {
      action.href = link
      action.textContent = label
    }
    steps.hidden = !instructions
    steps.replaceChildren(...(instructions ?? []).map(instruction => {
      const item = document.createElement("li")
      item.textContent = instruction
      return item
    }))
  }

  function patience() {
    settingUp = settingUp ?? Date.now()
    return Date.now() - settingUp < 180000 ? "This usually takes about a minute. Keep this page open; it updates by itself." : "This is taking longer than usual. It needs " + owner + "'s Mac to be online, so this page keeps trying."
  }

  function schedule(delay) {
    clearTimeout(timer)
    timer = setTimeout(refresh, delay)
  }

  function offer(text, label, link) {
    if (!onDevice) {
      show("Open this link on your iPhone.", "AppShelf installs " + owner + "'s apps on the iPhone that opens this page.")
    } else if (!inSafari) {
      show("Open this link in Safari.", "Copy the link and paste it into Safari. Other browsers cannot set up AppShelf.")
    } else {
      show(text, "The profile only shares this iPhone's device ID, and it removes itself right away." + requirement, link, label, [
        "Tap " + label + " below, then tap Allow.",
        "Open Settings and tap Profile Downloaded near the top (or General, then VPN & Device Management). Tap Install and enter your passcode.",
        "Safari opens this page again and finishes by itself."
      ])
    }
  }

  function forget() {
    try {
      localStorage.removeItem("request")
    } catch {}
    request = null
  }

  async function fetchState(path) {
    try {
      const response = await fetch(path, { cache: "no-store" })
      return await response.json()
    } catch {
      show("Can't reach AppShelf right now.", "This page tries again automatically.")
      schedule(15000)
      return null
    }
  }

  function showReady(greeting, link, request) {
    show(greeting + "This iPhone is ready.", "Tap Install AppShelf, then Install. Open AppShelf from your Home Screen, allow notifications, and install the apps you want." + (inSafari ? "" : " If nothing happens, open this page in Safari.") + " Once it's installed, come back and tap Open AppShelf so " + owner + " can see which apps you use.", link, "Install AppShelf")
    if (request) {
      opener.href = "appshelf://joined?request=" + encodeURIComponent(request)
      opener.hidden = false
    }
  }

  function showUnsupported() {
    show("This iPhone needs iOS " + (minimum || "a newer version") + " or later.", "Update it in Settings, then General, then Software Update. Then open this link again.")
  }

  async function refreshInvite() {
    if (failure === "system") {
      showUnsupported()
      return
    }
    const state = await fetchState("/invite/" + invite)
    if (!state) {
      return
    }
    const greeting = state.name ? "Hi " + state.name + "! " : ""
    switch (state.status) {
    case "invited":
      offer(greeting + "You're invited to get " + owner + "'s apps on this iPhone.", "Get Started", "/invite/" + invite + ".mobileconfig")
      schedule(10000)
      return
    case "pending":
    case "approved":
    case "preparing":
      show(greeting + "Setting up AppShelf for this iPhone…", patience())
      schedule(5000)
      return
    case "waiting":
      show(greeting + "Waiting for " + owner + " to confirm this iPhone.", "This page updates by itself once it's confirmed.")
      schedule(10000)
      return
    case "failed":
      show(greeting + "Setup did not finish yet.", owner + " can see the problem and will try again. This page updates by itself.")
      schedule(30000)
      return
    case "ready":
      showReady(greeting, state.install, state.request)
      return
    case "declined":
    case "removed":
      show("This invite is no longer active.", "Ask " + owner + " if you still need access.")
      return
    case "cancelled":
      show("This invite was cancelled or has expired.", "Ask " + owner + " to send you a new one.")
      return
    default:
      show("Getting your invite ready…", "This usually takes a few seconds. It needs " + owner + "'s Mac to be online, so this page keeps trying.")
      schedule(Date.now() - opened < 120000 ? 5000 : 30000)
      return
    }
  }

  async function refreshRequest() {
    if (failure === "busy") {
      show("Too many requests are waiting.", owner + " has too many open requests right now. Try again later.")
      return
    }
    if (failure === "system") {
      showUnsupported()
      return
    }
    if (failure) {
      offer("This page only works on an iPhone or iPad.", "Request Access", "/request.mobileconfig")
      return
    }
    if (!request) {
      offer("Get " + owner + "'s apps on this iPhone.", "Request Access", "/request.mobileconfig")
      return
    }
    const state = await fetchState("/status/" + request)
    if (!state) {
      return
    }
    switch (state.status) {
    case "pending":
    case "waiting":
      show("Request sent. " + owner + " has been notified.", "This page updates once you're approved. You can also close it and open the link again later.")
      break
    case "approved":
    case "preparing":
      show(owner + " approved this iPhone. Setting up AppShelf for it…", patience())
      break
    case "failed":
      show(owner + " approved this iPhone, but setup did not finish yet.", owner + " can see the problem and will try again. This page updates when it's ready.")
      schedule(30000)
      return
    case "ready":
      showReady("", state.install, state.request)
      return
    case "declined":
      forget()
      offer(owner + " declined this request.", "Request Again", "/request.mobileconfig")
      return
    case "removed":
      forget()
      offer(owner + " removed this iPhone from AppShelf.", "Request Again", "/request.mobileconfig")
      return
    default:
      forget()
      offer("Get " + owner + "'s apps on this iPhone.", "Request Access", "/request.mobileconfig")
      return
    }
    schedule(10000)
  }

  const refresh = invite ? refreshInvite : refreshRequest
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
      clearTimeout(timer)
      refresh()
    }
  })
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
    const invitation = url.pathname.match(/^\/invite\/([0-9a-f]{32})(\.mobileconfig)?$/)
    if (request.method === "GET" && invitation) {
      return invitation[2] ? inviteProfile(invitation[1], request, env) : inviteStatus(invitation[1], env)
    }
    if (request.method === "GET" && url.pathname === "/") {
      return page(env)
    }
    return new Response("Not found", { status: 404, headers: baseHeaders })
  }
}
