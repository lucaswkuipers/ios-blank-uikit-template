---
name: uikit-app
description: Turn new personal iOS app ideas into programmatic UIKit apps with icons, signing, simulator checks, and private internal TestFlight delivery. Use for new iOS app implementation, respecting explicit framework choices; not existing-app rewrites or planning-only requests.
---

# UIKit App

Create the project in one call:

```sh
uikit-app create Calories --icon calories --output /absolute/new/Calories
```

Choose a letters-and-digits project name and a short icon purpose or SF Symbol. The CLI reuses `/Users/lucas/ios-blank-uikit-template`, integrates Icon Studio's fixed preset, and applies personal team/bundle defaults from `~/.config/uikit-app/config.json`. The icon is already generated; no separate icon command is needed. No Xcode GUI, catalog browsing, or project-file assembly. Fallback executable: `~/.local/bin/uikit-app`.

Implement the requested features in the generated Swift sources using programmatic UIKit and no storyboards. Preserve the minimal scene startup; add lifecycle handling only when needed. Source files inside the app folder join the target automatically. The default deployment target matches the selected Xcode SDK; honor requested compatibility with `--deployment-target`. `--team` and `--bundle-id` override personal defaults.

After implementation:

```sh
uikit-app check /absolute/Calories
```

This verifies a signed Debug device build and simulator startup, returns compact JSON with app, log, and screenshot paths, and restores a simulator it booted to shutdown. It uses a dedicated simulator per project; pass `--simulator <UDID>` to select one. Review the screenshot and check the app's actual behavior as appropriate; startup alone does not establish feature correctness.

Signing uses existing credentials first. If provisioning is missing, retry once with `--allow-provisioning-updates` for development signing.

Finish new app ideas with private TestFlight delivery:

```sh
uikit-app testflight /absolute/Calories
```

This is authorized for Lucas's personal account, team `AR7T5G5Z83`, with only his configured tester in the internal Personal group. Never use amo's account. The CLI checks the remote account and project team, archives, uploads an internal-only build, waits for Apple processing, and assigns the build. Keys stay in `~/.config/uikit-app`; never print or commit them. Determine the app's actual encryption use and set `ITSAppUsesNonExemptEncryption` accordingly before delivery.

For `needs-app-record`, create the returned iOS app record once at the returned App Store Connect URL, verifying the personal account. Use the supplied name, bundle ID, SKU, English (U.S.), and Limited Access. Then rerun the command. Apple's public API cannot create this record.

Only `available-to-internal-tester` confirms delivery; it does not prove installation or notification receipt. For `processing`, rerun the same command to resume, without recreating the app or upload. If `sourcesChanged` is true, rerun to deliver the newer source. Use `--retry-upload` only after the upload log shows a failed attempt; it retains the same build number. Account/legal failures need user action. For missing initial configuration, read [setup and recovery](references/testflight-setup.md).

Physical-device installation, external testing, and App Store submission remain separate user requests.
