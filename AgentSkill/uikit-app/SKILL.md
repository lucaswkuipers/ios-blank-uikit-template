---
name: uikit-app
description: Turn new personal iOS app ideas into programmatic UIKit apps with icons, private personal GitHub repositories, and TestFlight updates on push. Use for new iOS app implementation, respecting explicit framework choices; not existing-app rewrites or planning-only requests.
---

# UIKit App

Create the app, implement and commit its features, then publish:

```sh
uikit-app create Calories --icon calories --output /absolute/new/Calories
# Implement, review, and commit the requested features on main.
uikit-app publish /absolute/new/Calories
```

Use a letters-and-digits project name and a short icon purpose or SF Symbol. Creation reuses Lucas's programmatic UIKit template, integrates Icon Studio's preset, and configures personal signing. No storyboards, catalog browsing, Xcode GUI, project boilerplate, or separate icon command. Source files inside the app folder join the target automatically. Fallback: `~/.local/bin/uikit-app`.

Creation also initializes and pushes a **private** `lucaswkuipers/<Name>` repository, sets Lucas's personal commit identity, and configures a repository-specific GitHub Actions runner on his Mac. The scaffold commit skips CI. Subsequent pushes to `main` trigger TestFlight delivery; `publish` pushes committed changes and waits for the exact commit's result. Do not also run a local delivery for that push. The Mac must be awake and its runner service available; the phone can be on any network. For setup recovery, use `uikit-app setup-repo <directory>`. Use `create --local-only` only for explicitly local-only work or disposable validation. Keep credentials and build outputs out of Git; never use amo or create public app repositories.

Focus reasoning on the app's features and behavior. Determine its actual encryption use and declare `ITSAppUsesNonExemptEncryption` in Info.plist before delivery. Do not invent an exemption for an app that needs a declaration. The deployment target defaults to the selected SDK; use `--deployment-target` for requested compatibility.

The workflow runs `testflight`, which verifies the personal account and project, registers the app and Lucas's internal tester through HTTP, builds one signed Release archive, verifies it, uploads an internal-only build, waits for Apple, and confirms the tester's access. This is authorized for personal team `AR7T5G5Z83` and only the configured Account Holder. Never use amo. Keys and Apple sessions remain local; never print or commit them. No per-app browser/computer-use work.

Simulator verification is optional. Use `uikit-app check /absolute/Calories` when useful for the requested UI/behavior or explicitly requested. It builds only for the simulator, launches, captures a screenshot, and shuts down a simulator it booted. Review the screenshot and verify relevant behavior; startup alone is not functional testing. `--simulator <UDID>` chooses a device. Do not add a redundant Debug device build: delivery already verifies the signed Release archive.

Let `publish` perform its own workflow wait; keep output compact. Only `available-to-internal-tester` confirms availability, not installation or notification receipt. Rerunning `publish` reuses the same commit's run. A failed workflow links its logs; fix and push, or rerun the workflow to resume an interrupted delivery. Direct `testflight` remains available for explicit manual delivery and recovery. For `sourcesChanged: true` or `sources-changed-during-build`, finish edits and rerun. A failed/uncertain upload retains its build; inspect the returned log before `--retry-upload`.

For `needs-apple-login`, Lucas runs `uikit-app login` in Terminal and enters password/2FA there, never in chat. This is occasional account authentication, not per-app registration. For missing setup or other recovery, read [setup and recovery](references/testflight-setup.md). Honor requests to skip delivery. Physical-device installation, external testing, and App Store submission require separate requests.
