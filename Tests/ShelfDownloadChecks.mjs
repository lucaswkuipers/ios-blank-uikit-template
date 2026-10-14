import assert from "node:assert/strict"
import { createHmac } from "node:crypto"
import { test } from "node:test"
import { download } from "../CLI/ShelfRequests/downloads.mjs"

const token = "github_pat_fixture_artifact_only"
const environment = { ARTIFACT_TOKEN: token }
const origin = "https://appshelf.example"

function ticket(overrides) {
  return {
    assetID: 123,
    bundleIdentifier: "com.lucaswkuipers.Example",
    build: "2",
    name: 'A & B <"Example"> 🎵',
    expires: Math.floor(Date.now() / 1000) + 3600,
    ...overrides
  }
}

function link(value, file) {
  const encoded = Buffer.from(JSON.stringify(value)).toString("base64url")
  const signature = createHmac("sha256", token).update(`AppShelf install v1\n${encoded}`).digest("hex")
  return `${origin}/download/${encoded}/${signature}/${file}`
}

function assetURL(overrides) {
  const values = { blob: Date.now() + 300000, jwt: Date.now() + 300000, ...overrides }
  const url = new URL("https://release-assets.githubusercontent.com/example")
  url.searchParams.set("se", new Date(values.blob).toISOString())
  url.searchParams.set("jwt", `header.${Buffer.from(JSON.stringify({ exp: values.jwt / 1000 })).toString("base64url")}.signature`)
  return url.href
}

test("manifests work without GitHub or a Mac and preserve the exact app and package ticket", async context => {
  context.mock.method(globalThis, "fetch", () => assert.fail("A manifest must not need an upstream request"))
  const value = ticket({})
  const url = link(value, "manifest.plist")
  const response = await download(new Request(url), environment)
  assert.equal(response.status, 200)
  assert.equal(response.headers.get("cache-control"), "no-store")
  const text = await response.text()
  assert.ok(text.includes("<string>com.lucaswkuipers.Example</string>"))
  assert.ok(text.includes("<string>2</string>"))
  assert.ok(text.includes("A &amp; B &lt;&quot;Example&quot;&gt; 🎵"))
  assert.ok(text.includes(link(value, "package.ipa")))
  assert.ok(!text.includes(token))
  const head = await download(new Request(url, { method: "HEAD" }), environment)
  assert.equal(head.status, 200)
  assert.equal(await head.text(), "")
})

test("tampered, expired, overlong, malformed and unconfigured tickets fail before any GitHub request", async context => {
  context.mock.method(globalThis, "fetch", () => assert.fail("Rejected tickets must not reach GitHub"))
  const url = link(ticket({}), "package.ipa")
  const signature = url.split("/").at(-2)
  const tampered = url.replace(signature, (signature[0] === "0" ? "1" : "0") + signature.slice(1))
  assert.equal((await download(new Request(tampered), environment)).status, 403)
  for (const overrides of [{ expires: 1 }, { expires: Math.floor(Date.now() / 1000) + 7200 }]) {
    assert.equal((await download(new Request(link(ticket(overrides), "manifest.plist")), environment)).status, 410)
  }
  for (const value of [null, ticket({ assetID: -1 }), ticket({ bundleIdentifier: "another.owner" }), ticket({ build: "<1>" }), ticket({ name: "Invalid\u0000name" })]) {
    assert.equal((await download(new Request(link(value, "manifest.plist")), environment)).status, 400)
  }
  assert.equal((await download(new Request(url), {})).status, 503)
  assert.equal((await download(new Request(url + "?target=https://evil.example"), environment)).status, 404)
  assert.equal((await download(new Request(url, { method: "POST" }), environment)).status, 405)
  assert.equal((await download(new Request(`${origin}/download/${"a".repeat(2049)}/${"0".repeat(64)}/package.ipa`), environment)).status, 404)
})

test("each package request resolves a fresh private URL and never forwards credentials", async context => {
  const calls = []
  const location = assetURL({})
  context.mock.method(globalThis, "fetch", async (url, options) => {
    calls.push({ url: new URL(url), options })
    return new Response(null, { status: 302, headers: { location } })
  })
  const url = link(ticket({}), "package.ipa")
  for (const method of ["GET", "HEAD"]) {
    const response = await download(new Request(url, { method }), environment)
    assert.equal(response.status, 302)
    assert.equal(response.headers.get("location"), location)
    assert.equal(response.headers.get("authorization"), null)
    assert.equal(response.headers.get("referrer-policy"), "no-referrer")
    assert.equal(response.headers.get("cache-control"), "no-store")
  }
  assert.equal(calls.length, 2)
  assert.notEqual(calls[0].url.href, calls[1].url.href)
  for (const call of calls) {
    assert.equal(call.url.origin, "https://api.github.com")
    assert.equal(call.url.pathname, "/repos/lucaswkuipers/AppShelf-builds/releases/assets/123")
    assert.equal(call.options.headers.authorization, `Bearer ${token}`)
    assert.equal(call.options.redirect, "manual")
  }
})

test("unsafe or nearly expired GitHub redirects never reach the installer", async context => {
  let location
  context.mock.method(globalThis, "fetch", async () => new Response(null, { status: 302, headers: { location } }))
  for (const value of [
    "https://evil.example/package.ipa", "http://release-assets.githubusercontent.com/package.ipa",
    assetURL({ blob: Date.now() + 30000 }), assetURL({ jwt: Date.now() + 30000 }),
    assetURL({}).replace("https://", "https://credential@"), assetURL({}).replace(".com/", ".com:8443/")
  ]) {
    location = value
    const response = await download(new Request(link(ticket({}), "package.ipa")), environment)
    assert.equal(response.status, 502)
    assert.equal(response.headers.get("location"), null)
  }
})

test("direct GitHub responses stream before the package finishes and support byte ranges and HEAD", async context => {
  let streamController
  const stream = new ReadableStream({ start(controller) { streamController = controller } })
  let upstreamBody = stream
  const calls = []
  context.mock.method(globalThis, "fetch", async (url, options) => {
    calls.push(options)
    return new Response(upstreamBody, { status: options.headers.range ? 206 : 200, headers: {
      "content-length": "3", "content-range": "bytes 0-2/10", "accept-ranges": "bytes", "set-cookie": "private"
    } })
  })
  const url = link(ticket({}), "package.ipa")
  const response = await download(new Request(url, { headers: { range: "bytes=0-2" } }), environment)
  assert.equal(response.status, 206)
  assert.equal(response.headers.get("content-range"), "bytes 0-2/10")
  assert.equal(response.headers.get("set-cookie"), null)
  assert.equal(calls[0].headers.range, "bytes=0-2")
  streamController.enqueue(new TextEncoder().encode("ipa"))
  streamController.close()
  assert.equal(await response.text(), "ipa")
  upstreamBody = "ipa"
  const head = await download(new Request(url, { method: "HEAD" }), environment)
  assert.equal(head.status, 200)
  assert.equal(head.headers.get("content-length"), "3")
  assert.equal(await head.text(), "")
  assert.equal((await download(new Request(url, { headers: { range: "invalid" } }), environment)).status, 416)
  assert.equal(calls.length, 2)
})

test("upstream failures do not leak responses or credentials", async context => {
  const upstream = context.mock.method(globalThis, "fetch", async () => new Response(token, { status: 403 }))
  const request = new Request(link(ticket({}), "package.ipa"))
  const forbidden = await download(request, environment)
  assert.equal(forbidden.status, 502)
  assert.ok(!(await forbidden.text()).includes(token))
  upstream.mock.mockImplementation(async () => new Response("missing", { status: 404 }))
  assert.equal((await download(request, environment)).status, 404)
  upstream.mock.mockImplementation(async () => { throw new Error(token) })
  const unavailable = await download(request, environment)
  assert.equal(unavailable.status, 502)
  assert.ok(!(await unavailable.text()).includes(token))
})
