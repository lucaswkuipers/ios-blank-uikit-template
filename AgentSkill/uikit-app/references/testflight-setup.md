# Personal TestFlight setup and recovery

Personal Apple team: `AR7T5G5Z83`. Account Holder and internal tester: read the configured personal account; never infer it from Git identity. The shared commands and skill are the same for Claude and Codex.

## Credentials

Inspect `~/.config/uikit-app/testflight.json` before creating keys. The dedicated `UIKit App Delivery` team key has App Manager access. Configure it with:

```sh
uikit-app setup-testflight --key /absolute/AuthKey_KEYID.p8 --key-id KEYID --issuer PERSONAL_ISSUER_UUID --tester PERSONAL_ACCOUNT_HOLDER_EMAIL --account-bundle com.lucaswkuipers.Blank
```

Setup verifies the anchor bundle's seed ID is `AR7T5G5Z83` and the tester is the Account Holder. It stores the key locally with mode 0600. Never print or commit keys, passwords, session exports, or 2FA codes. Do not weaken account checks to resolve an error.

Initial API-key provisioning may require the personal Apple portal. Private-key downloads are one-time: after a timeout, check for the named local file before retrying. Safari previously succeeded where the in-app browser lost the download. Revoke only unusable keys created during this setup, not unrelated keys. Lucas may need Touch ID or to accept a new Apple agreement.

Distribution signing/upload uses the personal Apple Account already in Xcode, explicitly pinned to `AR7T5G5Z83`. The App Manager key manages provisioning/TestFlight but does not have cloud distribution signing permission. Renew Xcode authentication with the personal Account Holder when necessary. Xcode subprocesses use Apple system tools first in PATH to avoid Homebrew rsync packaging incompatibility.

## Browser-free app registration

Install the small `asc` executable once (`brew install asc`), then Lucas runs:

```sh
uikit-app login
```

He enters password/2FA directly in Terminal. `asc` manages its own Apple CLI session and secure password storage. Telemetry is disabled for calls from this tool. Its session is separate from Safari/Xcode; never scrape browser cookies. Apple can expire sessions or demand new 2FA. `uikit-app` reuses/refreshes the session when possible and returns `needs-apple-login` when human authentication is required.

The Swift bridge uses asc's documented temporary session export, removes it immediately after import, and keeps an isolated in-memory HTTP session. It verifies the live account email and public provider ID against the API-verified personal issuer before any private mutation. It creates app records, limits app access, and assigns the Account Holder to the internal group through Apple's private HTTP endpoints. The public API verifies the resulting app and exact tester membership. There is no browser UI automation per app.

App registration and first internal-tester enrollment rely on Apple's private web endpoints, which can change. Public API calls handle ongoing delivery. If Apple changes a private endpoint, fix the narrow bridge using its structured error and primary implementation references; do not silently claim availability or start a browser loop.

Implementation references:
- [asc web-session lifecycle](https://github.com/rorkai/App-Store-Connect-CLI/blob/main/commands/web.mdx)
- [asc app-creation payload](https://github.com/rorkai/App-Store-Connect-CLI/blob/main/internal/web/apps.go)
- [fastlane bulk internal tester assignment](https://github.com/fastlane/fastlane/blob/master/spaceship/lib/spaceship/connect_api/testflight/testflight.rb)

## Delivery and recovery

`uikit-app testflight /absolute/project` owns registration, one Release archive, signature verification, upload, internal processing, and tester assignment. Simulator checks are optional and separate. Declare actual encryption use before delivery.

Logs and resumable state live in `~/Library/Caches/uikit-app/<project>-<path-hash>/`. A bundle-level lock prevents concurrent deliveries from different checkouts. Safe reads retry transient failures; uncertain writes are reconciled before retrying. Source edits during archiving stop before upload. Edits while an earlier build is processing are reported with `sourcesChanged: true` at completion; rerun for the new source.

`--wait-seconds 0` checks processing once; normal calls wait up to 30 minutes without agent polling. `processing` means rerun the same command. `--retry-upload` retries an uncertain/failed upload with the same archive/build number after checking Apple first; inspect the upload log before using it. Do not recreate the project, app record, or API key to recover an upload.

Internal tester IDs are app-specific. Never reuse an arbitrary tester ID found by email across the account. Delivery verifies the Personal internal group contains exactly the configured Account Holder and rejects other testers in groups that can automatically receive the build.

Only `available-to-internal-tester` establishes delivery. Lucas accepts a new app's invitation and taps Install in TestFlight; later builds may update automatically according to his TestFlight settings. Apple processing, 2FA, updated agreements, notification delivery, and the phone's install/update behavior are outside the CLI's control.
