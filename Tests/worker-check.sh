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
token="$(openssl rand -hex 32)"
prefix="itms-services://?action=download-manifest&url=https://gist.githubusercontent.com/lucaswkuipers/0123456789abcdef/raw/"

cp "$repository/CLI/ShelfRequests/worker.js" "$repository/CLI/ShelfRequests/schema.sql" "$work/"
printf 'profile fixture' > "$work/request.mobileconfig"
cat > "$work/wrangler.toml" <<EOF
name = "appshelf"
main = "worker.js"
compatibility_date = "2026-09-01"
workers_dev = true
preview_urls = false
rules = [{ type = "Data", globs = ["**/*.mobileconfig"], fallthrough = false }]

[vars]
OWNER_NAME = "Lucas"
INSTALL_LINK = "${prefix}AppShelf.plist"
INSTALL_PREFIX = "$prefix"
MINIMUM_SYSTEM = "27.0"

[[d1_databases]]
binding = "DB"
database_name = "appshelf-requests"
database_id = "00000000-0000-0000-0000-000000000000"
EOF
printf 'ADMIN_TOKEN=%s\n' "$token" > "$work/.dev.vars"
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
    cat > "$work/device-$3.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>DEVICE_NAME</key>
	<string>Alex&apos;s iPhone$(printf '\033')[2J</string>
	<key>PRODUCT</key>
	<string>$1</string>
	<key>UDID</key>
	<string>$2</string>
	<key>VERSION</key>
	<string>24A335</string>
</dict>
</plist>
EOF
    openssl smime -sign -binary -nodetach -outform der -signer "$work/device.pem" -inkey "$work/device.key" -in "$work/device-$3.plist" -out "$work/device-$3.p7s"
}

enroll() {
    curl -s -o /dev/null -w '%{redirect_url}' -X POST --data-binary @"$work/device-$1.p7s" "$base/enroll${2:+?invite=$2}"
}

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/device.key" -out "$work/device.pem" -subj "/CN=Device" -days 1 2> /dev/null
admin=(-H "Authorization: Bearer $token")

check "page" "$(curl -s -o "$work/page.html" -w '%{http_code}' "$base/")" "200"
/usr/bin/python3 -I -c 'import re, sys; sys.stdout.write(re.search(r"<script>(.*)</script>", open(sys.argv[1]).read(), re.S).group(1))' "$work/page.html" > "$work/page.js"
node --check "$work/page.js"
grep -q '\[hidden\] { display: none !important; }' "$work/page.html" || { printf 'FAIL: hidden buttons must not render\n'; exit 1; }
grep -q 'AppShelf needs iOS " + minimum' "$work/page.js" || { printf 'FAIL: page script lost the iOS requirement\n'; exit 1; }
check "profile type" "$(curl -s -o /dev/null -w '%{content_type}' "$base/request.mobileconfig")" "application/x-apple-aspen-config"

device iPhone17,1 00008140-000A1B2C3D4E5F60 alex
first="$(enroll alex)"
id="${first##*request=}"
check "enroll redirects to the request" "$first" "$base/?request=$id"
check "asking twice keeps one open request" "$(enroll alex)" "$base/?request=$id"
check "pending status hides the link" "$(curl -s "$base/status/$id")" '{"status":"pending","install":null}'
check "admin needs the token" "$(curl -s -o /dev/null -w '%{http_code}' "$base/admin/requests")" "401"
check "admin rejects a guessed token" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer undefined' "$base/admin/requests")" "401"
listed="$(curl -s "${admin[@]}" "$base/admin/requests")"
check "admin lists the pending device" "$(printf '%s' "$listed" | grep -o "\"deviceName\":\"Alex's iPhone\[2J\"" | head -1)" "\"deviceName\":\"Alex's iPhone[2J\""
check "malformed admin bodies are rejected" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d 'not json' "$base/admin/requests/$id")" "400"
check "invalid status" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"status":"bogus"}' "$base/admin/requests/$id")" "400"
check "ready status" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"status":"ready"}' "$base/admin/requests/$id")" "200"
check "ready falls back to the configured link" "$(curl -s "$base/status/$id")" "{\"status\":\"ready\",\"install\":\"${prefix}AppShelf.plist\"}"
check "pinned link" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d "{\"link\":\"${prefix}abc/AppShelf.plist\"}" "$base/admin/install")" "200"
check "ready uses the pinned link" "$(curl -s "$base/status/$id")" "{\"status\":\"ready\",\"install\":\"${prefix}abc/AppShelf.plist\"}"
check "foreign links are rejected" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"link":"itms-services://?action=download-manifest&url=https://evil.example/AppShelf.plist"}' "$base/admin/install")" "400"
again="$(enroll alex)"
check "an approved iPhone asking again needs a new approval" "$([[ "$again" == "$base/?request=$id" ]] && echo reused || echo new)" "new"
second="${again##*request=}"
check "the new request starts pending" "$(curl -s "$base/status/$second")" '{"status":"pending","install":null}'
check "declined" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"status":"declined"}' "$base/admin/requests/$second")" "200"
third="$(enroll alex)"
check "a declined iPhone can ask again" "$(curl -s "$base/status/${third##*request=}")" '{"status":"pending","install":null}'
device MacBookPro18,1 00008112-000A1B2C3D4E5F61 mac
check "computers are sent back with an explanation" "$(enroll mac)" "$base/?error=iphone"
check "garbage is sent back with an explanation" "$(curl -s -o /dev/null -w '%{redirect_url}' -X POST --data-binary 'not a device' "$base/enroll")" "$base/?error=device"
for index in $(seq 1 30); do
    device iPhone17,1 "$(printf '00008140-%016X' "$index")" "$index"
done
enrollments=()
for index in $(seq 1 30); do
    enroll "$index" > "$work/result-$index" &
    enrollments+=($!)
done
wait "${enrollments[@]}"
open="$(curl -s "${admin[@]}" "$base/admin/requests" | grep -o '"status":"pending"' | wc -l | tr -d ' ')"
check "the waiting cap holds under parallel requests" "$open" "20"
check "extra requests are told to try later" "$(cat "$work"/result-* | grep -o 'error=busy' | wc -l | tr -d ' ')" "11"
check "unknown requests" "$(curl -s -o /dev/null -w '%{http_code}' "$base/status/00000000-0000-0000-0000-000000000000")" "404"

invite="$(openssl rand -hex 16)"
fixture="$(printf 'invite profile fixture' | base64)"
offer() {
    printf '{"token":"%s","name":"%s","profile":"%s"}' "$1" "$2" "$fixture"
}
sam="$(offer "$invite" Sam)"
short="$(offer short Sam)"
nameless="$(offer "$invite" "$(printf '\033')")"
check "invites need the admin token" "$(curl -s -o /dev/null -w '%{http_code}' -d "$sam" "$base/admin/invites")" "401"
check "malformed invites are rejected" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d "$short" "$base/admin/invites")" "400"
check "nameless invites are rejected" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d "$nameless" "$base/admin/invites")" "400"
check "invite upload" "$(curl -s "${admin[@]}" -d "$sam" "$base/admin/invites")" '{"updated":1}'
check "uploading twice keeps one invite" "$(curl -s "${admin[@]}" -d "$sam" "$base/admin/invites")" '{"updated":0}'
check "an unused invite greets its guest" "$(curl -s "$base/invite/$invite")" '{"status":"invited","install":null,"name":"Sam"}'
check "the invite profile type" "$(curl -s -o "$work/invite.mobileconfig" -w '%{content_type}' "$base/invite/$invite.mobileconfig")" "application/x-apple-aspen-config"
check "the invite profile is the uploaded one" "$(cat "$work/invite.mobileconfig")" "invite profile fixture"
device iPhone16,1 00008130-000A1B2C3D4E5F70 sam
check "an invite enrollment returns to the invite" "$(enroll sam "$invite")" "$base/?invite=$invite"
check "invites skip the waiting cap" "$(curl -s "$base/invite/$invite")" '{"status":"pending","install":null,"name":"Sam"}'
pending="$(curl -s "${admin[@]}" "$base/admin/requests")"
check "the Mac sees which invite a request used" "$(printf '%s' "$pending" | grep -o "\"invite\":\"$invite\"" | head -1)" "\"invite\":\"$invite\""
check "a used invite no longer hands out its profile" "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$base/invite/$invite.mobileconfig")" "302 $base/?invite=$invite"
check "the same iPhone using its invite again returns to it" "$(enroll sam "$invite")" "$base/?invite=$invite"
device iPhone16,1 00008130-000A1B2C3D4E5F71 other
check "another iPhone with a used invite has to ask" "$(enroll other "$invite" | grep -o 'error=busy')" "error=busy"
used="$(printf '%s' "$pending" | grep -o "{[^}]*\"invite\":\"$invite\"[^}]*}" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)"
check "ready" "$(curl -s -o /dev/null -w '%{http_code}' "${admin[@]}" -d '{"status":"ready"}' "$base/admin/requests/$used")" "200"
check "a ready invite shows the install link" "$(curl -s "$base/invite/$invite")" "{\"status\":\"ready\",\"install\":\"${prefix}abc/AppShelf.plist\",\"name\":\"Sam\"}"
removal="$(printf '{"token":"%s"}' "$invite")"
check "used invites are kept" "$(curl -s "${admin[@]}" -d "$removal" "$base/admin/invites/remove")" '{"updated":0}'
cancelled="$(openssl rand -hex 16)"
kim="$(offer "$cancelled" Kim)"
curl -s -o /dev/null "${admin[@]}" -d "$kim" "$base/admin/invites"
removal="$(printf '{"token":"%s"}' "$cancelled")"
check "unused invites can be cancelled" "$(curl -s "${admin[@]}" -d "$removal" "$base/admin/invites/remove")" '{"updated":1}'
check "a cancelled invite is unknown" "$(curl -s -o /dev/null -w '%{http_code}' "$base/invite/$cancelled")" "404"
check "a cancelled invite profile returns to the page" "$(curl -s -o /dev/null -w '%{http_code}' "$base/invite/$cancelled.mobileconfig")" "302"
listed="$(printf '[{"token":"%s","request":"%s"}]' "$invite" "$used")"
check "the Mac lists invites" "$(curl -s "${admin[@]}" "$base/admin/invites")" "$listed"
waiting="$(openssl rand -hex 16)"
again="$(offer "$waiting" Alex)"
curl -s -o /dev/null "${admin[@]}" -d "$again" "$base/admin/invites"
alex="$(curl -s "${admin[@]}" "$base/admin/requests" | grep -o '{"id":"[^"]*","udid":"00008140-000A1B2C3D4E5F60"' | cut -d'"' -f4)"
curl -s -o /dev/null "${admin[@]}" -d '{"status":"waiting"}' "$base/admin/requests/$alex"
check "an invite takes over an open request" "$(enroll alex "$waiting")" "$base/?invite=$waiting"
check "the taken-over request goes back to the Mac" "$(curl -s "$base/status/$alex")" '{"status":"pending","install":null}'
printf 'Passed worker page script, hidden buttons, profile, enrollment, approval for every request, admin auth, status transitions, pinned install links, device checks, the atomic waiting cap, and single-use invites.\n'
