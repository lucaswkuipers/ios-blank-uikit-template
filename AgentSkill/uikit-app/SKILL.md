---
name: uikit-app
description: Turn new personal iOS app ideas into programmatic UIKit apps with icons, private personal GitHub repositories, and AppShelf updates on push. TestFlight is an explicit alternative. Use for new iOS app implementation, respecting framework overrides; not existing-app rewrites or planning-only requests.
---

# UIKit App

Create the app, implement and commit its features, then publish:

```sh
uikit-app create Calories --icon calories --output /absolute/new/Calories
# Implement, review, and commit the requested features on main.
uikit-app publish /absolute/new/Calories
```

Use a letters-and-digits project name and a short icon purpose or SF Symbol. Creation reuses Lucas's programmatic UIKit template, integrates Icon Studio's preset, and configures personal signing. No storyboards, catalog browsing, Xcode GUI, project boilerplate, or separate icon command. Source files inside the app folder join the target automatically. Fallback: `~/.local/bin/uikit-app`.

Creation also initializes and pushes a **private** `lucaswkuipers/<Name>` repository, sets Lucas's personal commit identity, and configures a repository-specific GitHub Actions runner on his Mac. The scaffold commit skips CI. This Mac defaults to AppShelf: subsequent pushes to `main` publish a signed build to the private artifact repository. `publish` pushes committed changes and waits for the exact commit's result. Do not also run a local delivery for that push. The Mac must be awake and its runner and shelf link-refresh services available; the phone can be on any network. For setup recovery, use `uikit-app setup-repo <directory>`. Use `create --local-only` only for explicitly local-only work or disposable validation. Keep credentials and build outputs out of Git; never use amo or create public app repositories.

Focus reasoning on the app's features and behavior. Determine its actual encryption use and declare `ITSAppUsesNonExemptEncryption` in Info.plist before delivery. Do not invent an exemption for an app that needs a declaration. The deployment target defaults to the selected SDK; use `--deployment-target` for requested compatibility.

The shelf workflow runs `direct`: it verifies the personal account and private source repo, registers the bundle and Ad Hoc profile through Apple's API, builds one signed Release archive for Lucas's registered iPhone, verifies the exported IPA, and publishes it to private `lucaswkuipers/AppShelf-builds`. The AppShelf phone app has read-only artifact access; no source or signing access. Use only personal team `AR7T5G5Z83`, never amo. No per-app browser/computer-use setup, Apple password, TestFlight registration, or Apple processing wait is needed for this route. Lucas opens AppShelf and taps Install / Update; iOS still requires installation confirmation.

Simulator verification is optional. Use `uikit-app check /absolute/Calories` when useful for the requested UI/behavior or explicitly requested. It builds only for the simulator, launches, captures a screenshot, and shuts down a simulator it booted. Review the screenshot and verify relevant behavior; startup alone is not functional testing. `--simulator <UDID>` chooses a device. Do not add a redundant Debug device build: delivery already verifies the signed Release archive.

Let `publish` perform its own workflow wait; keep output compact. `available-in-shelf` confirms catalog availability, not installation or notification receipt. Rerunning `publish` reuses the same commit's run. A failed workflow links its logs; fix and push, or rerun the workflow to resume an interrupted delivery. For `sourcesChanged: true` or `sources-changed-during-build`, finish edits and rerun. Read [direct shelf setup and recovery](references/direct-shelf.md) only when needed. Signing expires and the Mac must keep temporary install links fresh; do not promise indefinite or silent installation.

For an explicitly requested TestFlight app, use `create ... --delivery testflight`; existing projects retain the route recorded in `.uikit-app.json` (legacy projects without a route use TestFlight). `uikit-app testflight <directory>` remains the manual alternative for an existing app. It registers the app and internal tester, archives, uploads, and waits for `available-to-internal-tester`. Do not enable two push workflows. For `needs-apple-login`, Lucas runs `uikit-app login` in Terminal and enters password/2FA there, never in chat. For recovery, read [TestFlight setup](references/testflight-setup.md). Honor requests to skip delivery. Remote device control, external testing, and App Store submission require separate requests.
