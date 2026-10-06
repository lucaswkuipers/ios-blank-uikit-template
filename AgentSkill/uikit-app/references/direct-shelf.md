# Direct personal shelf (experimental)

The current default remains the verified TestFlight workflow. Direct Ad Hoc distribution is being validated; do not switch new apps to it until a real iPhone install and update pass.

The implementation uses private `lucaswkuipers/AppShelf-builds` release assets and a separate private UIKit client, `lucaswkuipers/AppShelf`. The phone gets only a fine-grained Contents read-only artifact token, like Hop. Source and signing credentials remain on the Mac. The publisher uses Lucas's personal GitHub CLI login on the Mac and verifies repository ownership and privacy before writes.

Commands:

```sh
uikit-app setup-direct --device <personal-iPhone-UDID> --name <device-name>
uikit-app package <project-directory> --build <number>
uikit-app direct <committed-project-directory>
uikit-app setup-shelf-refresh
uikit-app refresh-shelf
```

`setup-direct` verifies the personal Apple account, registers only the selected device if needed, and creates/imports a personal Distribution identity. The first use can require Lucas to approve a macOS Keychain prompt. No password belongs in chat or a repository.

`package` builds one signed Release archive, exports with a personal Ad Hoc profile containing exactly the configured iPhone, then verifies the exported IPA's signature, bundle/build identity, profile, and expiry. Signing configuration lives in `~/.config/uikit-app/direct.json`; private signing material never belongs in Git.

`direct` requires a private personal source repo and committed files, uploads an immutable app release, checks GitHub's size and SHA256, and updates the catalog only for the current main commit. Draft uploads are recoverable. It returns `available-in-shelf`, which means catalog availability, not physical installation.

The `catalog` release body contains schema 1 JSON. App releases contain signed IPA files and metadata. Catalog manifest assets contain temporary GitHub package URLs, never a PAT. The shelf resolves a temporary manifest URL with its read-only credential, validates it, then opens `itms-services`. Authorization is never forwarded to GitHub's asset host or the iOS installer.

Small release asset URLs currently have a five-minute JWT lifetime even when the blob-signature expiry is an hour. Use the earlier expiry. `setup-shelf-refresh` installs a user LaunchAgent that checks every minute and refreshes links with under two minutes left; it retains older manifests for two hours to protect in-progress installations. This requires the Mac to stay awake. Installed apps continue working without the Mac until their signing expires. Frequent manifest writes consume GitHub API limits; scaling to a large catalog will need a different install-manifest strategy.

The shelf client accepts an ignored `ShelfAccess.generated.json` bootstrap file (`{"token":"..."}`), imports it into the iPhone's device-only Keychain, and allows replacement in Settings. Its manual workflow copies this file from `~/.config/uikit-app/shelf-access.json`; never substitute the broad gh OAuth token. Credential creation and read-only scope verification are one-time setup still required before device validation.

Do not claim silent installation, reliable background notifications, device receipt, or remote install/update success from HTTP or simulator checks. iOS installation requires confirmation. TestFlight remains available through the existing CLI as fallback.
