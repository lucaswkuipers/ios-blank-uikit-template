#!/bin/bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
server=""
trap 'if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
export npm_config_cache="$HOME/Library/Caches/uikit-app/npm" WRANGLER_SEND_METRICS=false
wrangler=(npx --yes wrangler@4.143.0)
port=8791
base="http://127.0.0.1:$port"

cp "$repository/CLI/ShelfRequests/worker.js" "$repository/CLI/ShelfRequests/schema.sql" "$work/"
printf 'profile fixture' > "$work/request.mobileconfig"
cat > "$work/wrangler.toml" <<'EOF'
name = "appshelf"
main = "worker.js"
compatibility_date = "2026-09-01"
workers_dev = true
preview_urls = false
rules = [{ type = "Data", globs = ["**/*.mobileconfig"], fallthrough = false }]

[vars]
OWNER_NAME = "Lucas"
INSTALL_LINK = "itms-services://?action=download-manifest&url=https://example.com/raw/AppShelf.plist"
MINIMUM_SYSTEM = "27.0"

[[d1_databases]]
binding = "DB"
database_name = "appshelf-requests"
database_id = "00000000-0000-0000-0000-000000000000"
EOF
printf 'ADMIN_TOKEN=worker-check-token\n' > "$work/.dev.vars"
cd "$work"
"${wrangler[@]}" d1 execute appshelf-requests --local --file schema.sql --yes > /dev/null
"${wrangler[@]}" dev --local --ip 127.0.0.1 --port "$port" > dev.log 2>&1 &
server=$!
curl --silent --retry 30 --retry-connrefused --retry-delay 1 --output /dev/null "$base/"

check() {
    if [[ "$2" != "$3" ]]; then
        printf 'FAIL: %s (expected %s, got %s)\n' "$1" "$3" "$2"
        exit 1
    fi
}

device() {
    cat > "$work/device.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>DEVICE_NAME</key>
	<string>Alex&apos;s iPhone</string>
	<key>PRODUCT</key>
	<string>$1</string>
	<key>UDID</key>
	<string>$2</string>
	<key>VERSION</key>
	<string>24A335</string>
</dict>
</plist>
EOF
    openssl smime -sign -binary -nodetach -outform der -signer "$work/device.pem" -inkey "$work/device.key" -in "$work/device.plist" -out "$work/device.p7s"
}

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/device.key" -out "$work/device.pem" -subj "/CN=Device" -days 1 2> /dev/null
admin=(-H "Authorization: Bearer worker-check-token")
check "page" "$(curl -s -o "$work/page.html" -w '%{http_code}' "$base/")" "200"
/usr/bin/python3 -I -c 'import re, sys; sys.stdout.write(re.search(r"<script>(.*)</script>", open(sys.argv[1]).read(), re.S).group(1))' "$work/page.html" > "$work/page.js"
node --check "$work/page.js"
grep -q 'AppShelf needs iOS " + minimum' "$work/page.js" || { printf 'FAIL: page script lost the iOS requirement\n'; exit 1; }
check "profile type" "$(curl -s -o /dev/null -w '%{content_type}' "$base/request.mobileconfig")" "application/x-apple-aspen-config"
device iPhone17,1 00008140-000A1B2C3D4E5F60
location="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -X POST --data-binary @"$work/device.p7s" "$base/enroll")"
check "enroll redirect" "${location%% *}" "301"
id="${location##*request=}"
check "repeat enroll keeps the request" "$(curl -s -o /dev/null -w '%{redirect_url}' -X POST --data-binary @"$work/device.p7s" "$base/enroll")" "$base/?request=$id"
check "pending status hides the link" "$(curl -s "$base/status/$id")" '{"status":"pending","install":null}'
check "admin needs the token" "$(curl -s -o /dev/null -w '%{http_code}' "$base/admin/requests")" "401"
check "admin lists the device" "$(curl -s "${admin[@]}" "$base/admin/requests" | grep -o "Alex's iPhone" | head -1)" "Alex's iPhone"
check "invalid status" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"status":"bogus"}' "$base/admin/requests/$id")" "400"
check "ready status" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"status":"ready"}' "$base/admin/requests/$id")" "200"
check "ready falls back to the configured link" "$(curl -s "$base/status/$id")" '{"status":"ready","install":"itms-services://?action=download-manifest&url=https://example.com/raw/AppShelf.plist"}'
check "pinned link" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"link":"itms-services://?action=download-manifest&url=https://example.com/raw/abc/AppShelf.plist"}' "$base/admin/install")" "200"
check "ready uses the pinned link" "$(curl -s "$base/status/$id")" '{"status":"ready","install":"itms-services://?action=download-manifest&url=https://example.com/raw/abc/AppShelf.plist"}'
check "foreign links are rejected" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"link":"https://evil.example"}' "$base/admin/install")" "400"
check "declined" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"status":"declined"}' "$base/admin/requests/$id")" "200"
curl -s -o /dev/null -X POST --data-binary @"$work/device.p7s" "$base/enroll"
check "a declined iPhone can ask again" "$(curl -s "$base/status/$id")" '{"status":"pending","install":null}'
device MacBookPro18,1 00008112-000A1B2C3D4E5F61
check "computers are rejected" "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$work/device.p7s" "$base/enroll")" "400"
check "garbage is rejected" "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'not a device' "$base/enroll")" "400"
for index in $(seq 1 19); do
    device iPhone17,1 "$(printf '00008140-%016X' "$index")"
    curl -s -o /dev/null -X POST --data-binary @"$work/device.p7s" "$base/enroll"
done
device iPhone17,1 00008140-00000000000000FF
check "waiting requests are capped" "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$work/device.p7s" "$base/enroll")" "429"
check "unknown requests" "$(curl -s -o /dev/null -w '%{http_code}' "$base/status/00000000-0000-0000-0000-000000000000")" "404"
printf 'Passed worker page script, profile, enrollment, re-requests, admin auth, status transitions, pinned install links, device checks, and the waiting cap.\n'
