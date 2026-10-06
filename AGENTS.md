# Programmatic UIKit template

`XcodeTemplate/iOS/Application/Programmatic UIKit App.xctemplate` is the source of truth for app source files, assets, and Info.plist. `CLI/main.swift` copies it and fills `CLI/project.pbxproj`; keep that project's build settings consistent with TemplateInfo.plist when changing template defaults.

Install the Swift CLI with `./CLI/install.sh`. Personal signing defaults live outside the repository in `~/.config/uikit-app/config.json`; never add credentials here. `AgentSkill/uikit-app` is shared with Codex and Claude through their skill-directory symlinks.

Validate generator changes by creating a fresh scratch app and running `uikit-app check` on it. Report signed build and simulator evidence separately from physical-device testing. Keep generated apps and build products outside the repository.

`CLI/TestFlight.swift` implements personal internal-only delivery. Keep the fixed personal team guard, remote account verification, single-tester group checks, and internal-only export setting. Run `./Tests/run.sh` for local behavior checks. End-to-end TestFlight validation additionally requires a real personal-account upload; never equate local tests with delivery.
