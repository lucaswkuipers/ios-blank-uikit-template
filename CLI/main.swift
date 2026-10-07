import CryptoKit
import Foundation

struct Simulator: Decodable {
    let name: String
    let udid: String
    let state: String
    let deviceTypeIdentifier: String?
}

struct SimulatorList: Decodable {
    let devices: [String: [Simulator]]
}

let repository = Bundle.main.executableURL!.resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()

func create(name: String, options: Options) throws {
    try validate(name, pattern: "^[A-Za-z][A-Za-z0-9]*$", label: "project name (use letters and digits)")
    guard let output = options.values["--output"], let icon = options.values["--icon"], !icon.isEmpty else {
        throw CommandError(message: "Required: --output <new-directory> --icon <purpose-or-symbol>")
    }
    let configurationURL = files.homeDirectoryForCurrentUser.appendingPathComponent(".config/uikit-app/config.json")
    let configuration: [String: String]
    if files.fileExists(atPath: configurationURL.path) {
        configuration = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: configurationURL))
    } else {
        configuration = [:]
    }
    guard let team = options.values["--team"] ?? configuration["team"] else {
        throw CommandError(message: "Provide --team <development-team-id> or set team in \(configurationURL.path)")
    }
    guard let bundleIdentifier = options.values["--bundle-id"] ?? configuration["bundlePrefix"].map({ "\($0).\(name)" }) else {
        throw CommandError(message: "Provide --bundle-id or set bundlePrefix in \(configurationURL.path)")
    }
    let deploymentTarget = try options.values["--deployment-target"] ?? run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"], log: nil)
    guard let delivery = DeliveryRoute(rawValue: options.values["--delivery"] ?? configuration["delivery"] ?? "testflight") else {
        throw CommandError(message: "Delivery must be shelf or testflight.")
    }
    try validate(team, pattern: "^[A-Z0-9]{10}$", label: "team")
    try validate(bundleIdentifier, pattern: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", label: "bundle identifier")
    try validate(deploymentTarget, pattern: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", label: "deployment target")
    let destination = URL(fileURLWithPath: output).standardizedFileURL
    guard !files.fileExists(atPath: destination.path) else {
        throw CommandError(message: "Output already exists: \(destination.path)")
    }
    let parent = destination.deletingLastPathComponent()
    try files.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(".uikit-app-\(UUID().uuidString)")
    try files.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: staging) }
    let source = staging.appendingPathComponent(name)
    try files.createDirectory(at: source, withIntermediateDirectories: false)
    let template = repository.appendingPathComponent("XcodeTemplate/iOS/Application/Programmatic UIKit App.xctemplate")
    for file in ["SceneDelegate.swift", "ViewController.swift", "Info.plist", "Assets.xcassets", "ShelfVersionReceipt.swift", "ShelfVersions.entitlements"] {
        try files.copyItem(at: template.appendingPathComponent(file), to: source.appendingPathComponent(file))
    }
    let project = staging.appendingPathComponent("\(name).xcodeproj")
    let schemes = project.appendingPathComponent("xcshareddata/xcschemes")
    try files.createDirectory(at: schemes, withIntermediateDirectories: true)
    var contents = try String(contentsOf: repository.appendingPathComponent("CLI/project.pbxproj"), encoding: .utf8)
    for (key, value) in ["__NAME__": name, "__TEAM__": team, "__BUNDLE_IDENTIFIER__": bundleIdentifier, "__DEPLOYMENT_TARGET__": deploymentTarget] {
        contents = contents.replacingOccurrences(of: key, with: value)
    }
    try contents.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
    let reference = "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"A0D4B65830599F6B0039D3A4\" BuildableName=\"\(name).app\" BlueprintName=\"\(name)\" ReferencedContainer=\"container:\(name).xcodeproj\"/>"
    let scheme = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="2700" version="1.3">
      <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">\(reference)</BuildActionEntry></BuildActionEntries></BuildAction>
      <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(reference)</BuildableProductRunnable></LaunchAction>
      <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(reference)</BuildableProductRunnable></ProfileAction>
      <AnalyzeAction buildConfiguration="Debug"/>
      <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
    </Scheme>
    """
    try scheme.write(to: schemes.appendingPathComponent("\(name).xcscheme"), atomically: true, encoding: .utf8)
    try files.copyItem(at: repository.appendingPathComponent(".gitignore"), to: staging.appendingPathComponent(".gitignore"))
    let metadata = Project(name: name, bundleIdentifier: bundleIdentifier, delivery: delivery)
    try JSONEncoder().encode(metadata).write(to: staging.appendingPathComponent(".uikit-app.json"))
    let instructions = """
    # \(name)

    Programmatic UIKit app; no storyboards or SwiftUI. App files in `\(name)/` join the Xcode target automatically.

    Use the shared `uikit-app` skill. Implement the requested features, commit on main, then run `uikit-app publish <this-directory>`. The CLI pushes and waits for the exact commit's delivery; do not run a duplicate local archive or delivery. The selected route is `\(delivery.rawValue)` in `.uikit-app.json`. `uikit-app check <this-directory>` is optional for simulator verification.

    Automatic delivery is restricted to personal Apple team `AR7T5G5Z83` and private `lucaswkuipers` repositories. Keep credentials and build outputs out of Git. Preserve the generated icon unless replacement is requested. Honor requests to skip delivery. AppShelf availability does not mean installation; iOS requires confirmation. Notifications are currently skipped.
    """
    try instructions.write(to: staging.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "@AGENTS.md\n".write(to: staging.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    let iconOutput = staging.appendingPathComponent(".icon-export")
    let installedIconStudio = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/iconstudio").path
    let iconStudio = files.isExecutableFile(atPath: installedIconStudio) ? installedIconStudio : "/Applications/Icon Studio.app/Contents/MacOS/iconstudio"
    try run(iconStudio, ["app", icon, "--platform", "ios", "--output", iconOutput.path], log: nil)
    let appIcon = source.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try files.removeItem(at: appIcon)
    try files.copyItem(at: iconOutput.appendingPathComponent("AppIcon.appiconset"), to: appIcon)
    try files.removeItem(at: iconOutput)
    try files.moveItem(at: staging, to: destination)
    var result = ["project": destination.appendingPathComponent("\(name).xcodeproj").path, "sources": destination.appendingPathComponent(name).path, "bundleIdentifier": bundleIdentifier, "team": team, "deploymentTarget": deploymentTarget, "delivery": delivery.rawValue]
    if !options.localOnly {
        do {
            result["repository"] = try setupAppRepository(directory: destination.path, template: repository).url
        } catch {
            throw RequiredAction(result: "needs-github-setup", message: "App saved at \(destination.path). \(error.localizedDescription)", command: "uikit-app setup-repo \(destination.path)")
        }
    }
    try emit(result)
}

func check(directory: String, options: Options) throws {
    let root = URL(fileURLWithPath: directory).standardizedFileURL
    let metadata = try JSONDecoder().decode(Project.self, from: Data(contentsOf: root.appendingPathComponent(".uikit-app.json")))
    let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    let cache = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/\(metadata.name)-\(digest)")
    try files.createDirectory(at: cache, withIntermediateDirectories: true)
    let derivedData = cache.appendingPathComponent("DerivedData")
    let base = ["-project", root.appendingPathComponent("\(metadata.name).xcodeproj").path, "-scheme", metadata.name, "-configuration", "Debug", "-derivedDataPath", derivedData.path, "-quiet", "build"]
    let devicesText = try run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], log: nil)
    let devices = try JSONDecoder().decode(SimulatorList.self, from: Data(devicesText.utf8)).devices
    let simulator: String
    let wasBooted: Bool
    if let requested = options.values["--simulator"] {
        guard let device = devices.values.flatMap({ $0 }).first(where: { $0.udid == requested }) else {
            throw CommandError(message: "Simulator unavailable: \(requested)")
        }
        simulator = device.udid
        wasBooted = device.state == "Booted"
    } else {
        let simulatorName = "UIKit Check \(metadata.name) \(digest)"
        let sdk = try run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-version"], log: nil)
        let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-\(sdk.replacingOccurrences(of: ".", with: "-"))"
        guard let runtimeDevices = devices[runtime], let model = runtimeDevices.first(where: { $0.deviceTypeIdentifier?.contains("iPhone") == true })?.deviceTypeIdentifier else {
            throw CommandError(message: "No iPhone simulator for iOS \(sdk). Pass --simulator <available-UDID>.")
        }
        if let existing = runtimeDevices.first(where: { $0.name == simulatorName }) {
            simulator = existing.udid
            wasBooted = existing.state == "Booted"
        } else {
            simulator = try run("/usr/bin/xcrun", ["simctl", "create", simulatorName, model, runtime], log: nil)
            wasBooted = false
        }
    }
    status("Building for the simulator…")
    try run("/usr/bin/xcodebuild", base + ["-destination", "platform=iOS Simulator,id=\(simulator)", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"], log: cache.appendingPathComponent("simulator-build.log"))
    let simulatorApp = derivedData.appendingPathComponent("Build/Products/Debug-iphonesimulator/\(metadata.name).app")
    status("Launching in simulator \(simulator)…")
    if !wasBooted { try run("/usr/bin/xcrun", ["simctl", "boot", simulator], log: nil) }
    defer {
        if !wasBooted {
            do { try run("/usr/bin/xcrun", ["simctl", "shutdown", simulator], log: nil) }
            catch { status("Simulator cleanup failed: \(error.localizedDescription)") }
        }
    }
    try run("/usr/bin/xcrun", ["simctl", "bootstatus", simulator, "-b"], log: cache.appendingPathComponent("simulator-boot.log"))
    try run("/usr/bin/xcrun", ["simctl", "install", simulator, simulatorApp.path], log: nil)
    try run("/usr/bin/xcrun", ["simctl", "launch", "--terminate-running-process", simulator, metadata.bundleIdentifier], log: nil)
    Thread.sleep(forTimeInterval: 2)
    let processes = try run("/usr/bin/xcrun", ["simctl", "spawn", simulator, "launchctl", "list"], log: nil)
    guard processes.split(separator: "\n").contains(where: { line in
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        return fields.count >= 3 && Int(fields[0]) != nil && fields[2].hasPrefix("UIKitApplication:\(metadata.bundleIdentifier)[")
    }) else {
        throw CommandError(message: "App exited after launch. Inspect simulator crash logs for \(metadata.bundleIdentifier).")
    }
    let screenshot = cache.appendingPathComponent("simulator.png")
    try run("/usr/bin/xcrun", ["simctl", "io", simulator, "screenshot", screenshot.path], log: nil)
    try emit(["simulatorApp": simulatorApp.path, "simulator": simulator, "screenshot": screenshot.path, "logs": cache.path, "result": "simulator-launch-passed"])
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
        print("""
        uikit-app create <Name> --icon <purpose-or-symbol> --output <new-directory>
          [--team <ID>] [--bundle-id <ID>] [--deployment-target <version>] [--delivery shelf|testflight] [--local-only]
        uikit-app setup-repo <project-directory>
        uikit-app publish <project-directory>
        uikit-app check <project-directory> [--simulator <UDID>]
        uikit-app testflight <project-directory> [--wait-seconds <seconds>] [--retry-upload]
        uikit-app login
        uikit-app setup-direct --device <iPhone-UDID> --name <device-name>
        uikit-app package <project-directory> --build <number>
        uikit-app direct <project-directory>
        uikit-app refresh-shelf
        uikit-app setup-shelf-refresh
        uikit-app setup-testflight --key <file.p8> --key-id <ID> --issuer <UUID> --tester <email> --account-bundle <existing-personal-bundle-ID>

        Creates from the programmatic UIKit template and integrates an Icon Studio icon.
        create also creates a private lucaswkuipers repository and installs its Mac CI runner.
        --local-only skips GitHub and CI setup. setup-repo resumes or adds that setup later.
        Commit app features, then publish pushes main and waits for the app's selected delivery workflow.
        create uses the configured delivery route; --delivery shelf|testflight overrides it.
        Every subsequent push to main triggers delivery automatically while the Mac is available.
        check builds and launches in a simulator, captures a screenshot, and restores a simulator
        it booted to shutdown. Logs stay in Library/Caches.
        testflight registers the app and personal tester, verifies a signed Release archive,
        uploads, and waits for internal availability. No browser or simulator is required.
        check is optional for simulator/behavior verification; it is not needed before testflight.
        login performs the occasional Apple CLI password/2FA sign-in in Terminal.
        Personal defaults: ~/.config/uikit-app/config.json (team, bundlePrefix, and delivery).
        """)
    } else if arguments == ["login"] {
        try login()
    } else if arguments == ["refresh-shelf"] {
        try refreshShelf()
    } else if arguments == ["setup-shelf-refresh"] {
        try setupShelfRefresh()
    } else {
        guard arguments.count >= 2 else { throw CommandError(message: "Use uikit-app --help") }
        switch arguments[0] {
        case "setup-testflight":
            try setupTestFlight(options: Options(arguments.dropFirst(), allowed: ["--key", "--key-id", "--issuer", "--tester", "--account-bundle"]))
        case "setup-direct":
            try setupDirect(options: Options(arguments.dropFirst(), allowed: ["--device", "--name"]))
        case "package":
            let options = try Options(arguments.dropFirst(2), allowed: ["--build"])
            guard let build = options.values["--build"] else { throw CommandError(message: "Provide --build <number>") }
            let package = try packageDirect(directory: arguments[1], build: build)
            try emit(["result": "personal-package-ready", "app": package.name, "build": package.build, "path": package.path, "team": TestFlightConfiguration.personalTeam])
        case "testflight":
            try deliverTestFlight(directory: arguments[1], options: Options(arguments.dropFirst(2), allowed: ["--wait-seconds", "--retry-upload"]))
        case "direct":
            _ = try Options(arguments.dropFirst(2), allowed: [])
            try deliverDirect(directory: arguments[1])
        case "setup-repo":
            _ = try Options(arguments.dropFirst(2), allowed: [])
            let github = try setupAppRepository(directory: arguments[1], template: repository)
            try emit(["result": "private-repository-ready", "repository": github.url, "owner": "lucaswkuipers"])
        case "publish":
            _ = try Options(arguments.dropFirst(2), allowed: [])
            try publish(directory: arguments[1])
        case "create":
            try create(name: arguments[1], options: Options(arguments.dropFirst(2), allowed: ["--icon", "--output", "--team", "--bundle-id", "--deployment-target", "--delivery", "--local-only"]))
        case "check":
            try check(directory: arguments[1], options: Options(arguments.dropFirst(2), allowed: ["--simulator"]))
        default:
            throw CommandError(message: "Unknown command: \(arguments[0]). Use uikit-app --help")
        }
    }
} catch let action as RequiredAction {
    try? emit(["result": action.result, "message": action.message, "action": action.command])
    exit(2)
} catch {
    status(error.localizedDescription)
    exit(1)
}
