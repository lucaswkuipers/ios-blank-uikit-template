# ios-blank-uikit-template

Minimal programmatic UIKit iOS app template for Xcode. No storyboards, no boilerplate.

## Command line

Requires Xcode 27 or later and the local Icon Studio CLI.

```bash
./CLI/install.sh
uikit-app create Calories --icon calories --output /path/to/new/Calories \
  --team YOURTEAMID --bundle-id com.example.Calories
```

For repeated use, save `team` and `bundlePrefix` in `~/.config/uikit-app/config.json`:

```json
{"team":"YOURTEAMID","bundlePrefix":"com.example"}
```

Then agents only need:

```bash
uikit-app create Calories --icon calories --output /path/to/new/Calories
# Implement app features in the generated Swift sources.
uikit-app check /path/to/new/Calories
```

Creation copies the canonical template, writes a shared Xcode scheme, and integrates an icon with Lucas's Icon Studio preset. Output must be a new directory. The minimum iOS version defaults to the selected SDK; use `--deployment-target` to override it.

`check` builds and verifies a development-signed Debug device app, then builds, installs, launches, checks that the process stays alive, and captures a simulator screenshot. It uses a dedicated simulator per project and shuts it down afterward if it was not already booted. Pass `--simulator <UDID>` to choose another. JSON output contains the app paths, screenshot, and complete logs under `~/Library/Caches/uikit-app`; simulator startup is a smoke check, not a functional test suite.

Signing uses cached credentials. If needed, `--allow-provisioning-updates` allows Xcode to manage development signing through its configured account. This requires a usable Apple account and team; it does not install on a physical device or distribute the app.

`AgentSkill/uikit-app` provides short, automatically discoverable instructions for agents. The generated project remains a normal Xcode project and does not depend on the CLI to build.

## Xcode template

```bash
./XcodeTemplate/install.sh
```

Quit and reopen Xcode, then choose **File → New → Project → iOS → Application → Programmatic UIKit App**.
