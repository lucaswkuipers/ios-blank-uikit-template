---
name: uikit-app
description: Build new personal iOS apps with programmatic UIKit, icons, private GitHub repos, and AppShelf delivery on push. TestFlight is an explicit alternative. Excludes existing-app rewrites and planning-only requests; honor framework overrides.
---

# UIKit App

```sh
uikit-app create Calories --icon calories --output /absolute/new/Calories
# Implement the requested features and commit them on main.
uikit-app publish /absolute/new/Calories
```

Use a letters-and-digits name and a short icon purpose or SF Symbol. Creation handles the UIKit template, icon preset, signing configuration, private `lucaswkuipers` repo, Mac runner, and local AGENTS/CLAUDE instructions. Edit the returned `sources` directory; files join the target automatically. No storyboard, catalog browsing, template search, browser setup, or separate icon command. Fallback: `~/.local/bin/uikit-app`.

This Mac defaults to AppShelf. `publish` pushes and waits for that commit's workflow, starting it if CI was skipped. Rerun the same command to resume; follow a running command instead of launching duplicates. Do not add a local delivery or redundant device build. `available-in-shelf` confirms catalog availability; Lucas opens AppShelf and confirms Install / Update. Keep the Mac awake for builds and install-link refresh. Notifications are skipped.

Only personal team `AR7T5G5Z83` and private personal repos. Never use amo or commit credentials. Preserve existing icons and honor framework/delivery overrides. `--local-only` skips GitHub and delivery setup. Simulator verification is optional: `uikit-app check <directory>`; review its screenshot and relevant behavior.

For requested TestFlight, create with `--delivery testflight`, or manually run `uikit-app testflight <existing-directory>`. Existing apps retain their route. Never enable two push workflows. Declare actual encryption use before TestFlight upload. `available-to-internal-tester` confirms that route.

Read recovery details only when needed: [AppShelf](references/direct-shelf.md), [TestFlight/login](references/testflight-setup.md). `setup-repo` repairs repository/runner setup. Remote device control, external testing, and App Store submission require separate requests.
