# Direct personal shelf

AppShelf is this Mac's default for new personal apps. A signed AppShelf bootstrap was installed on Coppertino, and Lucas confirmed that CLIDeliveryCheck build 5 installed and opened through the shelf after a push-triggered delivery. TestFlight remains an explicit alternative.

The implementation uses private `lucaswkuipers/AppShelf-builds` release assets and a separate private UIKit client, `lucaswkuipers/AppShelf`. The phone gets only a fine-grained Contents read-only artifact token, like Hop. Source and signing credentials remain on the Mac. The publisher uses Lucas's personal GitHub CLI login on the Mac and verifies repository ownership and privacy before writes.

Commands:

```sh
uikit-app setup-direct --device <personal-iPhone-UDID> --name <device-name>
uikit-app package <project-directory> --build <number>
uikit-app direct <committed-project-directory>
uikit-app setup-shelf-refresh
uikit-app refresh-shelf
```

The machine-wide `delivery: shelf` setting makes `create` install the shelf push workflow and save that choice in `.uikit-app.json`; the same `publish` command waits for its `available-in-shelf` result. `--delivery testflight` overrides the route for a new app. Existing projects without a delivery field keep TestFlight. Do not leave two push-triggered delivery workflows in one app.

An explicit `publish` starts the workflow if the commit skipped CI or no push run appeared within 90 seconds. It checks the remote commit before dispatching and prevents concurrent publish waiters. If GitHub has accepted a dispatch but has not listed it after another 90 seconds, it reports pending; resume with `publish`, without manually dispatching another workflow. A completed publish reuses its existing run. Failed runs still require fixing the reported failure or rerunning that workflow.

`setup-direct` verifies the personal Apple account, registers only the selected device if needed, and creates/imports a personal Distribution identity. The first use can require Lucas to approve a macOS Keychain prompt. No password belongs in chat or a repository.

`package` builds one signed Release archive, exports with a personal Ad Hoc profile containing exactly the configured iPhone, then verifies the exported IPA's signature, bundle/build identity, profile, and expiry. Signing configuration lives in `~/.config/uikit-app/direct.json`; private signing material never belongs in Git.

`direct` requires a private personal source repo and committed files, uploads an immutable app release, checks GitHub's size and SHA256, and updates the catalog only for the current main commit. Draft uploads are recoverable. It returns `available-in-shelf`, which means catalog availability, not physical installation.

Both delivery routes reserve build numbers in `~/.config/uikit-app/build-numbers`; direct retries retain their reservation in `direct-deliveries`. This prevents a TestFlight fallback from reusing a newer direct build's version. Preserve these files alongside local credentials when moving to another Mac.

The `catalog` release body contains schema 1 JSON. App releases contain signed IPA files and metadata. Catalog manifest assets contain temporary GitHub package URLs, never a PAT. The shelf resolves a temporary manifest URL with its read-only credential, validates it, then opens `itms-services`. Authorization is never forwarded to GitHub's asset host or the iOS installer.

Small release asset URLs currently have a five-minute JWT lifetime even when the blob-signature expiry is an hour. Use the earlier expiry. `setup-shelf-refresh` installs a user LaunchAgent that checks every minute and refreshes links with under two minutes left; it retains older manifests for two hours to protect in-progress installations. This requires the Mac to stay awake. Installed apps continue working without the Mac until their signing expires. Frequent manifest writes consume GitHub API limits; scaling to a large catalog will need a different install-manifest strategy.

The shelf client accepts an ignored `ShelfAccess.generated.json` bootstrap file (`{"token":"..."}`), imports it into the iPhone's device-only Keychain, and allows replacement in Settings. Its push workflow copies this file from `~/.config/uikit-app/shelf-access.json`; never substitute the broad gh OAuth token. This one-time credential setup is complete. If rotated, verify private artifact reads succeed and private AppShelf source reads fail, and check the GitHub token's permissions remain Contents and Metadata read-only for AppShelf-builds alone. Binaries intentionally contain a recoverable artifact-only bootstrap credential, like Hop.

Do not claim silent installation, reliable background notifications, device receipt, or remote install/update success from HTTP or simulator checks. iOS installation requires confirmation. TestFlight remains available through the existing CLI as fallback.
