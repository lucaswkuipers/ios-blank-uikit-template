---
name: uikit-app
description: Create new personal iOS apps from Lucas's programmatic UIKit template, with an icon, automatic signing, and a simulator launch check. Use for new iOS app implementation, respecting explicit framework choices; not existing-app rewrites or planning-only requests.
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

Signing uses existing credentials first. If provisioning is missing, retry once with `--allow-provisioning-updates` to let the configured Xcode account manage development signing. Report account/permission failures; do not switch Apple accounts or seek private keys. Physical-device installation, distribution, and uploading are separate actions requested by the user.
