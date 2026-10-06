# Personal TestFlight setup

Use the personal App Store Connect account belonging to Lucas Werner Kuipers, Apple team `AR7T5G5Z83`. Read the Account Holder/tester email from that account's People page and the issuer ID from its Integrations page. Do not infer either from Git identity or a work account.

The dedicated team key is named `UIKit App Delivery`, with App Manager access. Inspect existing configuration before creating another key. Download the private key into a local file; never ask for its contents in chat. A one-time browser login or an updated Apple agreement may need Lucas's interaction.

If a browser reports a download timeout, first look for the named `.p8` file locally. Apple's key download is one-time: a consumed download cannot be retried. If the in-app browser did not save it, switch to Safari before generating a replacement with the same role, then revoke only the unusable keys created during this setup. Do not repeatedly consume downloads in the failing browser or touch unrelated keys. Safari may require Lucas's Touch ID for his personal passkey; the agent handles the remaining setup after sign-in.

Configure with:

```sh
uikit-app setup-testflight --key /absolute/AuthKey_KEYID.p8 --key-id KEYID --issuer PERSONAL_ISSUER_UUID --tester PERSONAL_ACCOUNT_HOLDER_EMAIL --account-bundle com.lucaswkuipers.Blank
```

The CLI verifies the key can see the existing personal bundle ID with seed ID `AR7T5G5Z83`, and verifies the tester is the account holder. It copies the key into `~/.config/uikit-app` with mode 0600 and saves metadata separately in `testflight.json`. Neither file belongs in a repository. If the anchor bundle is unavailable, inspect the personal developer portal for another existing identifier; do not substitute a work identifier or weaken the team check.

Distribution signing and upload use the personal Apple Account already signed in to Xcode, with the export explicitly pinned to `AR7T5G5Z83`. The App Manager API key handles account verification and TestFlight management; it does not have cloud distribution signing permission. If Xcode requires renewed authentication, sign in with the personal Account Holder. Xcode subprocesses put Apple system tools first in PATH to avoid Homebrew rsync incompatibility during IPA packaging.

Run `uikit-app testflight /absolute/project`. For a new app, it registers the explicit bundle identifier and returns `needs-app-record`; create the record in the personal portal and rerun. Authentication and delivery errors include concise diagnostics; full Xcode logs and resumable state are in `~/Library/Caches/uikit-app/<project>-<path-hash>/`.

For `needs-internal-tester`, use the returned group URL and Invite Testers to add only the configured Account Holder email, then rerun. Apple uses different internal tester records for each app; never reuse an arbitrary tester ID found by email across the account. The CLI verifies the group's membership before uploading.

`--wait-seconds 0` checks processing without waiting. Repeating the command after a successful upload reuses its build. `--retry-upload` retries an uncertain/failed upload with the same archive and build number after checking whether Apple already registered it. Inspect the upload log before using this option. Source changes before upload rebuild the archive; changes while Apple processes an earlier build are reported with `sourcesChanged: true` after that build completes.

Do not claim that a build reached TestFlight until the CLI confirms it, or that it installed on Lucas's phone without separate evidence. For a new app, Lucas accepts the invitation and taps Install in TestFlight; later builds can update automatically.
