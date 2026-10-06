---
name: uikit-app
description: Turn new personal iOS app ideas into programmatic UIKit apps with icons and automatic private internal TestFlight delivery. Use for new iOS app implementation, respecting explicit framework choices; not existing-app rewrites or planning-only requests.
---

# UIKit App

The normal path is two commands, with app implementation between them:

```sh
uikit-app create Calories --icon calories --output /absolute/new/Calories
# Implement the requested features.
uikit-app testflight /absolute/new/Calories
```

Use a letters-and-digits project name and a short icon purpose or SF Symbol. Creation reuses Lucas's programmatic UIKit template, integrates Icon Studio's preset, and configures personal signing. No storyboards, catalog browsing, Xcode GUI, project boilerplate, or separate icon command. Source files inside the app folder join the target automatically. Fallback: `~/.local/bin/uikit-app`.

Focus reasoning on the app's features and behavior. Determine its actual encryption use and declare `ITSAppUsesNonExemptEncryption` in Info.plist before delivery. Do not invent an exemption for an app that needs a declaration. The deployment target defaults to the selected SDK; use `--deployment-target` for requested compatibility.

`testflight` verifies the personal account and project, registers the app and Lucas's internal tester through HTTP, builds one signed Release archive, verifies it, uploads an internal-only build, waits for Apple, and confirms the tester's access. This is authorized for personal team `AR7T5G5Z83` and only the configured Account Holder. Never use amo. Keys and Apple sessions remain local; never print or commit them. No per-app browser/computer-use work.

Simulator verification is optional. Use `uikit-app check /absolute/Calories` when useful for the requested UI/behavior or explicitly requested. It builds only for the simulator, launches, captures a screenshot, and shuts down a simulator it booted. Review the screenshot and verify relevant behavior; startup alone is not functional testing. `--simulator <UDID>` chooses a device. Do not add a redundant Debug device build: delivery already verifies the signed Release archive.

Let the delivery command perform its own processing wait; keep output compact. Only `available-to-internal-tester` confirms availability, not installation or notification receipt. Rerunning unchanged sources reuses the delivery. For `processing`, rerun the same command to resume. For `sourcesChanged: true` or `sources-changed-during-build`, finish edits and rerun. A failed/uncertain upload retains its build; inspect the returned log before `--retry-upload`.

For `needs-apple-login`, Lucas runs `uikit-app login` in Terminal and enters password/2FA there, never in chat. This is occasional account authentication, not per-app registration. For missing setup or other recovery, read [setup and recovery](references/testflight-setup.md). Honor requests to skip delivery. Physical-device installation, external testing, and App Store submission require separate requests.
