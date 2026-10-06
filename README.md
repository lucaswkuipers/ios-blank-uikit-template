# ios-blank-uikit-template

Minimal programmatic UIKit iOS app template for Xcode. No storyboards, no boilerplate.

## Command line

Requires Xcode 27 or later, the local Icon Studio CLI, and GitHub CLI authenticated as Lucas's personal account. Automatic repository setup uses this Mac's `github.com-personal` SSH host.

```bash
./CLI/install.sh
uikit-app create Calories --icon calories --output /path/to/new/Calories \
  --team YOURTEAMID --bundle-id com.example.Calories --local-only
```

For repeated use, save `team`, `bundlePrefix`, and the delivery route in `~/.config/uikit-app/config.json`:

```json
{"team":"YOURTEAMID","bundlePrefix":"com.example","delivery":"shelf"}
```

Then agents only need:

```bash
uikit-app create Calories --icon calories --output /path/to/new/Calories
# Implement, review, and commit app features on main.
uikit-app publish /path/to/new/Calories
```

Creation copies the canonical template, writes a shared Xcode scheme, and integrates an icon with Lucas's Icon Studio preset. It creates a private `lucaswkuipers/<Name>` GitHub repository and installs a repository-specific GitHub Actions runner on this Mac. The first scaffold commit skips CI. Output must be a new directory. The minimum iOS version defaults to the selected SDK; use `--deployment-target` to override it. `--local-only` skips repository/runner setup; `uikit-app setup-repo <directory>` adds or resumes it later.

Every subsequent push to `main` triggers the route selected during creation. Lucas's Mac defaults to AppShelf; `--delivery testflight` chooses personal internal TestFlight instead. Existing projects retain their saved route, and legacy projects without a route use TestFlight. `publish` pushes committed changes and waits for the exact commit's workflow, checking its delivery result before reporting availability. GitHub queues the latest pending update while another delivery runs; it does not cancel an upload in progress. The Mac must be awake, online, and logged into the user session running the service. The phone can be on another network. Runner configuration and logs live under `~/.local/share/uikit-app/runners/<Name>`; Apple signing credentials stay on the Mac. Each runner is scoped to one private repository; PRs do not trigger delivery.

The CLI verifies the active personal GitHub account, remote ownership, and private visibility before pushing. It pins personal GitHub credentials and uses the personal SSH host. Existing public or other-owner remotes are rejected. Review and commit feature changes before publishing; failed runs link to GitHub logs, and rerunning the workflow resumes saved delivery state. Manual `testflight` remains available for recovery; do not run it in parallel with the same push's workflow.

Each delivery route performs one signed Release archive. Simulator startup is optional: `uikit-app check /path/to/Calories` builds only for the simulator, installs, launches, checks that the process stays alive, and captures a screenshot. It uses a dedicated simulator per project and shuts it down afterward if it was not already booted. Pass `--simulator <UDID>` to choose another. JSON output contains app paths, screenshot, and complete logs under `~/Library/Caches/uikit-app`; startup alone does not prove feature correctness.

`AgentSkill/uikit-app` provides short, automatically discoverable instructions for agents. The generated project remains a normal Xcode project and does not depend on the CLI to build.

## Private AppShelf delivery

The shelf workflow runs `uikit-app direct <directory>`. It signs an Ad Hoc build for the configured personal iPhone and publishes immutable artifacts to private `lucaswkuipers/AppShelf-builds`. The phone app reads that repository with a separate read-only token, validates a temporary installation manifest, and opens the iOS installer. Lucas confirms installation on the phone. There is no TestFlight processing wait and no paid hosting service.

The Mac's `uikit-app refresh-shelf` LaunchAgent keeps temporary GitHub install links valid. Keep the Mac awake for new installs and updates; already installed apps run independently until their signing expires. `available-in-shelf` means catalog availability, not installation receipt. Phone notifications are intentionally out of scope for now. See [direct shelf setup and recovery](AgentSkill/uikit-app/references/direct-shelf.md).

## Private TestFlight delivery

```bash
uikit-app testflight /path/to/Calories
```

This personal workflow is restricted to Lucas's team `AR7T5G5Z83` and `com.lucaswkuipers` bundle identifiers. Configure App Store Connect once with `uikit-app setup-testflight` (see `--help`). The setup verifies an existing personal bundle identifier and the Account Holder's email before storing the key locally with mode 0600. Source files never contain the key.

The command verifies account and project identity, registers the bundle and app, enrolls only the personal Account Holder in an internal group, builds one signed Release archive, and uploads with `testFlightInternalTestingOnly=true`. Registration and first tester enrollment use authenticated HTTP calls without browser UI automation. Install `asc` once (`brew install asc`), then run `uikit-app login` in Terminal for personal Apple password/2FA authentication. The CLI selects and verifies the personal provider; it never imports browser cookies. Apple may require renewed authentication later. See [setup and recovery](AgentSkill/uikit-app/references/testflight-setup.md).

Declare the app's actual encryption use with `ITSAppUsesNonExemptEncryption` before uploading. Registration uses Apple's private web endpoints, while verification and ongoing delivery use the public API. Private endpoint changes can require an update to the narrow Swift bridge.
A bundle-level lock excludes concurrent deliveries. Saved state preserves the build number and archive across retries; safe reads retry transient network failures. Sources changed during a build stop before upload. The default processing wait is 30 minutes; `--wait-seconds 0` checks once. Rerun the same command for pending builds. If an upload failed before confirmation, inspect the log before using `--retry-upload` to retry the same build. `available-to-internal-tester` confirms that Apple accepted the internal-only build and the configured tester's private group has access. It does not confirm a notification arrived or that the user installed the app. If `sourcesChanged` is true, run again to deliver the newer source.

Only the configured personal tester is added. Other testers in an automatically distributed internal group stop delivery before upload. The tool never submits a build for App Store review or external beta review.

Run `./Tests/run.sh` for the local account/provider-guard, HTTP-retry, clean-output, JWT, build-number, fingerprint, and saved-state checks. An actual TestFlight delivery is still required to validate account permissions, signing, upload, and Apple processing end to end.

## Xcode template

```bash
./XcodeTemplate/install.sh
```

Quit and reopen Xcode, then choose **File → New → Project → iOS → Application → Programmatic UIKit App**.
