# Personal TestFlight setup and recovery

Personal Apple team: `AR7T5G5Z83`. Account Holder and internal tester: read the configured personal account; never infer it from Git identity. The shared commands and skill are the same for Claude and Codex.

## Credentials

Inspect `~/.config/uikit-app/testflight.json` before creating keys. Unattended cloud signing requires an Admin team API key; App Manager access is insufficient. The installed configuration uses Lucas's existing personal Admin key. Configure a key with:

```sh
uikit-app setup-testflight --key /absolute/AuthKey_KEYID.p8 --key-id KEYID --issuer PERSONAL_ISSUER_UUID --tester PERSONAL_ACCOUNT_HOLDER_EMAIL --account-bundle com.lucaswkuipers.Blank
```

Setup verifies the anchor bundle's seed ID is `AR7T5G5Z83` and the tester is the Account Holder. It stores the key locally with mode 0600. Never print or commit keys, passwords, session exports, or 2FA codes. Do not weaken account checks to resolve an error.

Initial API-key provisioning may require the personal Apple portal. Private-key downloads are one-time: after a timeout, check for the named local file before retrying. Safari previously succeeded where the in-app browser lost the download. Revoke only unusable keys created during this setup, not unrelated keys. Lucas may need Touch ID or to accept a new Apple agreement.

Archive provisioning and distribution signing/upload pass the configured API key to `xcodebuild`, explicitly pinned to `AR7T5G5Z83`. This avoids depending on Xcode's interactive Apple login for routine delivery. Xcode subprocesses use Apple system tools first in PATH to avoid Homebrew rsync packaging incompatibility. See [Apple's cloud signing automation](https://developer.apple.com/videos/play/wwdc2021/10204/).

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

The normal agent path is create, implement/commit, then `uikit-app publish /absolute/project`. Private app repositories belong to `lucaswkuipers`; pushes to main trigger `.github/workflows/testflight.yml` on their repository-scoped Mac runner. The first scaffold commit contains `[skip ci]`. Workflows serialize delivery without cancelling an upload in progress, and only the latest pending update is kept. `publish` waits for its exact commit and verifies the final personal TestFlight result. Rerun it to wait again; do not start a duplicate local delivery for that push.

`uikit-app setup-repo /absolute/project` resumes GitHub/runner setup. A name collision without an existing origin stops instead of adopting an unrelated repository. Existing remotes must match the private personal repository. Commit authors use `Lucas Werner Kuipers <lucaswkuipers@gmail.com>`, and pushes use this Mac's `github.com-personal` SSH alias. Never change a repository's visibility as an automatic recovery step.

Runner services start in the user's macOS login session. Setup removes the runner's default `SessionCreate` setting so signing shares that session's unlocked keychain. The Mac must be awake and online, with Lucas logged in; signing may need renewed Apple authentication. GitHub queues jobs while the runner is unavailable. Runner files live in `~/.local/share/uikit-app/runners/<Name>` and service logs in `~/Library/Logs/actions.runner.lucaswkuipers-<Name>.uikit-app-<Name>/`. Keep runner workspaces free of spaces because GitHub's shell script execution can fail on such paths. Signing keys and sessions remain on the Mac. Inspect the linked failed run, fix and push, or rerun the workflow to resume its saved delivery. Each app gets a separate lightweight runner listener because personal GitHub repositories cannot share an organization-scoped runner.

`uikit-app testflight /absolute/project` is the workflow's delivery command and the manual recovery path. It owns registration, one Release archive, signature verification, upload, internal processing, and tester assignment. Simulator checks are optional and separate. Declare actual encryption use before delivery.

Logs and resumable state live in `~/Library/Caches/uikit-app/<project>-<path-hash>/`. A bundle-level lock prevents concurrent deliveries from different checkouts. Safe reads retry transient failures; uncertain writes are reconciled before retrying. Source edits during archiving stop before upload. Edits while an earlier build is processing are reported with `sourcesChanged: true` at completion; rerun for the new source.

Delivery also checks Apple's build-upload status before the processed build becomes visible, surfacing early failures instead of waiting indefinitely. Build numbering includes pending or failed uploads to avoid reusing their numbers.

`--wait-seconds 0` checks processing once; normal calls wait up to 30 minutes without agent polling. `processing` means rerun the same command. `--retry-upload` retries an uncertain/failed upload with the same archive/build number after checking Apple first; inspect the upload log before using it. For CI, use `gh workflow run testflight.yml --repo lucaswkuipers/<Name> --ref main -f retry-upload=true`, then `uikit-app publish <directory>` to wait. Do not recreate the project, app record, or API key to recover an upload.

Internal tester IDs are app-specific. Never reuse an arbitrary tester ID found by email across the account. Delivery verifies the Personal internal group contains exactly the configured Account Holder and rejects other testers in groups that can automatically receive the build.

Only `available-to-internal-tester` establishes delivery. Lucas accepts a new app's invitation and taps Install in TestFlight; later builds may update automatically according to his TestFlight settings. Apple processing, 2FA, updated agreements, notification delivery, and the phone's install/update behavior are outside the CLI's control.
