# Direct personal shelf

AppShelf is this Mac's default for new personal apps. A signed AppShelf bootstrap was installed on Coppertino, and Lucas confirmed that CLIDeliveryCheck build 5 installed and opened through the shelf after a push-triggered delivery. TestFlight remains an explicit alternative.

The implementation uses private `lucaswkuipers/AppShelf-builds` release assets and a separate private UIKit client, `lucaswkuipers/AppShelf`. The phone gets only a fine-grained Contents read-only artifact token, like Hop. Source and signing credentials remain on the Mac. The publisher uses Lucas's personal GitHub CLI login on the Mac and verifies repository ownership and privacy before writes.

Commands:

```sh
uikit-app setup-direct --device <personal-iPhone-UDID> --name <device-name>
uikit-app package <project-directory> --build <number>
uikit-app direct <committed-project-directory>
uikit-app setup-shelf-refresh
uikit-app setup-shelf-installs
uikit-app refresh-shelf
```

The machine-wide `delivery: shelf` setting makes `create` install the shelf push workflow and save that choice in `.uikit-app.json`; the same `publish` command waits for its `available-in-shelf` result. `--delivery testflight` overrides the route for a new app. Existing projects without a delivery field keep TestFlight. Do not leave two push-triggered delivery workflows in one app.

An explicit `publish` starts the workflow if the commit skipped CI or no push run appeared within 90 seconds. It checks the remote commit before dispatching and prevents concurrent publish waiters. If GitHub has accepted a dispatch but has not listed it after another 90 seconds, it reports pending; resume with `publish`, without manually dispatching another workflow. A completed publish reuses its existing run. Failed runs still require fixing the reported failure or rerunning that workflow.

Accepted dispatches are recorded per app and commit in `~/.config/uikit-app/workflow-dispatches`, so restarting the CLI does not dispatch again merely because GitHub has delayed listing the run. If a run was intentionally deleted, inspect GitHub before removing its matching local receipt or explicitly dispatching a replacement. A network error during dispatch can have an uncertain outcome; inspect the run list before retrying.

`setup-direct` verifies the personal Apple account, registers only the selected device if needed, and creates/imports a personal Distribution identity. The first use can require Lucas to approve a macOS Keychain prompt. No password belongs in chat or a repository.

`package` builds one signed Release archive, exports with a personal Ad Hoc profile containing exactly the shelf's iPhones (the configured iPhone plus any added with `share-shelf`), then verifies the exported IPA's signature, bundle/build identity, profile, and expiry. Signing configuration lives in `~/.config/uikit-app/direct.json`; private signing material never belongs in Git.

`direct` requires a private personal source repo and committed files, uploads an immutable app release, checks GitHub's size and SHA256, and updates the catalog only for the current main commit. Draft uploads are recoverable. It returns `available-in-shelf`, which means catalog availability, not physical installation.

Both delivery routes reserve build numbers in `~/.config/uikit-app/build-numbers`; direct retries retain their reservation in `direct-deliveries`. This prevents a TestFlight fallback from reusing a newer direct build's version. Preserve these files alongside local credentials when moving to another Mac.

The `catalog` release body contains schema 1 JSON. App releases contain signed IPA files and metadata. Catalog manifest assets contain temporary GitHub package URLs, never a PAT. The shelf resolves a temporary manifest URL with its read-only credential, validates it, then opens `itms-services`. Authorization is never forwarded to GitHub's asset host or the iOS installer.

Small release asset URLs currently have a five-minute JWT lifetime even when the blob-signature expiry is an hour. Use the earlier expiry. `setup-shelf-refresh` installs a user LaunchAgent that checks every minute and refreshes links with under two minutes left; it retains older manifests for two hours to protect in-progress installations. This requires the Mac to stay awake. Installed apps continue working without the Mac until their signing expires. Frequent manifest writes consume GitHub API limits; scaling to a large catalog will need a different install-manifest strategy.

The shelf client accepts an ignored `ShelfAccess.generated.json` bootstrap file (`{"token":"..."}`), imports it into the iPhone's device-only Keychain, and allows replacement in Settings. Its push workflow copies this file from `~/.config/uikit-app/shelf-access.json`; never substitute the broad gh OAuth token. This one-time credential setup is complete. If rotated, verify private artifact reads succeed and private AppShelf source reads fail, and check the GitHub token's permissions remain Contents and Metadata read-only for AppShelf-builds alone. Binaries intentionally contain a recoverable artifact-only bootstrap credential, like Hop.

`setup-shelf-installs` opts this Mac into automatic installs for the same iPhone as `direct.json`, saving its UDID in `~/.config/uikit-app/shelf-installs.json`. The existing minute refresh reads installed versions through CoreDevice and installs missing or newer catalog apps, without launching them. Same or newer device versions are preserved. It reuses local signed IPAs, caches downloaded packages, and checks checksums, app identity, signatures, and the shelf's current device-set profile before installing. Installation has a separate lock and does not hold the catalog lock. An unreachable or locked device, failed install, or failed verification is left for a later refresh. USB or an available paired wireless connection is required; this is not internet-based remote management. Removing `shelf-installs.json` disables automatic installs. Logs are in `~/Library/Logs/uikit-app/shelf-refresh{,-error}.log`.

Do not claim installation or update success from HTTP, simulator checks, or catalog availability. The Mac emits `installed-on-device` only after reading the exact version/build back from the phone; it never launches the app. Manual installation through AppShelf still uses iOS confirmation. TestFlight remains available through the existing CLI as fallback.

## Sharing the shelf

`uikit-app share-shelf --device <UDID> --name <device-name>` shares every shelf app with another person's iPhone at no extra cost. It registers the iPhone with the personal team (up to 100 iPhones per membership year), records it in `~/.config/uikit-app/shelf-sharing.json`, and re-signs each catalog app, AppShelf first, by dispatching its private repository's shelf workflow and waiting for the result. Profiles then contain exactly the configured iPhone plus every shared iPhone. Catalog entries record that set in `deviceSet`, and `direct` re-signs an unchanged commit whose set is outdated. Re-signs use new build numbers but are marked `silent`, so they send no announcements. New apps include every shared iPhone automatically.

The command then publishes the invite: the current AppShelf IPA and its install manifest in a secret gist under `lucaswkuipers`, and prints an `itms-services` link and a QR code (`~/Library/Caches/uikit-app/ShelfInvite/AppShelf-invite.png`). The manifest uses the gist's latest-revision URL and references the IPA by blob hash, so the link and QR code stay the same across updates; the command waits for GitHub's five-minute raw cache to serve the new manifest. The iPhone Camera opens the QR directly. Anyone with the link can download AppShelf and extract its artifact-only token, but iOS installs it only on registered iPhones. The shared AppShelf works like the owner's: installs through the shelf, CloudKit notifications on that person's own iCloud account, and install links that need this Mac awake. Mac-assisted installs stay limited to the configured iPhone. Every app currently requires iOS 27.

Rerun `share-shelf` without options to retry failed re-signs and reprint the invite. `share-shelf --remove <device-name-or-UDID>` revokes an iPhone: every app, including the invite's AppShelf, is re-signed without it, so it can no longer install or update anything. Apps already on that iPhone keep running until their profiles expire, because Ad Hoc has no per-device remote kill switch, and its AppShelf can still read the catalog until the artifact token is rotated. The iPhone stays registered with Apple and keeps counting toward the yearly limit; never disable it automatically. Do not claim a shared install worked until that person confirms it on their iPhone.

## Access requests

`uikit-app setup-shelf-requests` deploys `CLI/ShelfRequests/worker.js` as the `appshelf` Cloudflare Worker on the owner's free account, with a free D1 database (`appshelf-requests`, schema in `CLI/ShelfRequests/schema.sql`). It needs a one-time browser login with the command it prints when signed out (wrangler 4.143.0 with the CLI's own npm cache, because this Mac's default npm cache is not writable) and the existing invite gist. The worker URL is the link and QR code to share; setup also writes it to the catalog's `invitation` field, which AppShelf's owner Sharing screen shows. `~/.config/uikit-app/shelf-requests.json` holds the worker URL and the Mac's admin token; the token is a Worker secret, never in Git.

The page offers a Profile Service configuration profile, signed with the personal Apple Distribution identity. After the visitor installs it in Settings, iOS posts the UDID, model, build, and device name to `/enroll`; the worker stores a pending row and redirects Safari back to the page, which polls its status and shows the AppShelf install link only once approved. Nothing stays installed. Anyone can request; only the owner's approval adds an iPhone.

The minute refresh relays pending rows into CloudKit `ShelfAccessRequest` records (Publisher role only; record name is the request ID). Creating a record notifies the owner's AppShelf through the static-text `shelf-access-requests-v1` subscription, which avoids notification field arguments and the Development subscription prerequisite. AppShelf writes `approved`, `declined`, or `remove`. Statuses: `waiting`, `approved`, `preparing`, `ready` (AppShelf installable, other apps still re-signing), `shared`, `failed`, `remove`, `removing`, `remove-failed`. When no re-sign is running, the refresh registers approved iPhones, removes revoked ones, and starts a detached `uikit-app share-shelf` (own session; logs in `~/Library/Logs/uikit-app/shelf-share.log`). That run takes `shelf-share.lock`, re-signs AppShelf first, refreshes the invite, marks requests `ready`, re-signs the remaining apps, then marks them `shared` or `failed` and deletes completed removals. Declined requests are deleted; the visitor may request again. Failures stop in a visible state; Try Again in AppShelf retries.

The `ShelfAccessRequest` record type must exist in Production: import `CloudKit/schema.ckdb` from the AppShelf repository into Development with `cktool import-schema` (management token saved through `xcrun cktool save-token`), then deploy schema changes in CloudKit Console. The owner's iCloud account needs the `Publisher` role; AppShelf shows the Sharing button only when it can read these records.
