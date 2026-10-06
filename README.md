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

## Private TestFlight delivery

```bash
uikit-app testflight /path/to/Calories
```

This personal workflow is restricted to Lucas's team `AR7T5G5Z83` and `com.lucaswkuipers` bundle identifiers. Configure App Store Connect once with `uikit-app setup-testflight` (see `--help`). The setup verifies an existing personal bundle identifier and the Account Holder's email before storing the key locally with mode 0600. Source files never contain the key.

The command verifies account and project identity, registers a bundle identifier if needed, checks internal group membership, archives, and uploads with `testFlightInternalTestingOnly=true`. New apps return `needs-app-record` until their record is created once in the personal App Store Connect portal. Declare the app's actual encryption use with `ITSAppUsesNonExemptEncryption` before uploading.

Saved state preserves the build number and archive across retries. The default processing wait is 30 minutes; `--wait-seconds 0` checks once. Rerun the same command for pending builds. If an upload failed before confirmation, inspect the log before using `--retry-upload` to retry the same build. `available-to-internal-tester` confirms that Apple accepted the internal-only build and the configured tester's private group has access. It does not confirm a notification arrived or that the user installed the app. If `sourcesChanged` is true, run again to deliver the newer source.

Only the configured personal tester is added. Other testers in an automatically distributed internal group stop delivery before upload. The tool never submits a build for App Store review or external beta review.

Run `./Tests/run.sh` for the local account-guard, JWT, build-number, fingerprint, and saved-state checks. An actual TestFlight delivery is still required to validate account permissions, signing, upload, and Apple processing end to end.

## Xcode template

```bash
./XcodeTemplate/install.sh
```

Quit and reopen Xcode, then choose **File → New → Project → iOS → Application → Programmatic UIKit App**.
