import CryptoKit
import Foundation

struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Options {
    var values: [String: String] = [:]
    var provisioningUpdates = false

    init(_ arguments: ArraySlice<String>, allowed: Set<String>) throws {
        var remaining = Array(arguments)
        while !remaining.isEmpty {
            let key = remaining.removeFirst()
            guard allowed.contains(key) else {
                throw CommandError(message: "Unknown option: \(key)")
            }
            if key == "--allow-provisioning-updates" {
                provisioningUpdates = true
                continue
            }
            guard !remaining.isEmpty, !remaining[0].hasPrefix("--"), values[key] == nil else {
                throw CommandError(message: "Provide one value for \(key)")
            }
            values[key] = remaining.removeFirst()
        }
    }
}

struct Project: Codable {
    let name: String
    let bundleIdentifier: String
}

struct Simulator: Decodable {
    let name: String
    let udid: String
    let state: String
    let deviceTypeIdentifier: String?
}

struct SimulatorList: Decodable {
    let devices: [String: [Simulator]]
}

let files = FileManager.default
let repository = Bundle.main.executableURL!.resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()

func status(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@discardableResult
func run(_ executable: String, _ arguments: [String], log: URL?) throws -> String {
    let output = log ?? files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard files.createFile(atPath: output.path, contents: nil) else {
        throw CommandError(message: "Cannot create log: \(output.path)")
    }
    let handle = try FileHandle(forWritingTo: output)
    defer {
        try? handle.close()
        if log == nil { try? files.removeItem(at: output) }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    process.waitUntilExit()
    let text = try String(contentsOf: output, encoding: .utf8)
    guard process.terminationStatus == 0 else {
        let tail = text.split(separator: "\n").suffix(18).joined(separator: "\n")
        throw CommandError(message: "\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus))\(log.map { "; log: \($0.path)" } ?? "")\n\(tail)")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func validate(_ value: String, pattern: String, label: String) throws {
    guard value.range(of: pattern, options: .regularExpression) != nil else {
        throw CommandError(message: "Invalid \(label): \(value)")
    }
}

func emit(_ result: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}

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
    for file in ["SceneDelegate.swift", "ViewController.swift", "Info.plist", "Assets.xcassets"] {
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
    let metadata = Project(name: name, bundleIdentifier: bundleIdentifier)
    try JSONEncoder().encode(metadata).write(to: staging.appendingPathComponent(".uikit-app.json"))
    let iconOutput = staging.appendingPathComponent(".icon-export")
    let installedIconStudio = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/iconstudio").path
    let iconStudio = files.isExecutableFile(atPath: installedIconStudio) ? installedIconStudio : "/Applications/Icon Studio.app/Contents/MacOS/iconstudio"
    try run(iconStudio, ["app", icon, "--platform", "ios", "--output", iconOutput.path], log: nil)
    let appIcon = source.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    try files.removeItem(at: appIcon)
    try files.copyItem(at: iconOutput.appendingPathComponent("AppIcon.appiconset"), to: appIcon)
    try files.removeItem(at: iconOutput)
    try files.moveItem(at: staging, to: destination)
    try emit(["project": destination.appendingPathComponent("\(name).xcodeproj").path, "bundleIdentifier": bundleIdentifier, "team": team, "deploymentTarget": deploymentTarget])
}

func check(directory: String, options: Options) throws {
    let root = URL(fileURLWithPath: directory).standardizedFileURL
    let metadata = try JSONDecoder().decode(Project.self, from: Data(contentsOf: root.appendingPathComponent(".uikit-app.json")))
    let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    let cache = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/\(metadata.name)-\(digest)")
    try files.createDirectory(at: cache, withIntermediateDirectories: true)
    let derivedData = cache.appendingPathComponent("DerivedData")
    let base = ["-project", root.appendingPathComponent("\(metadata.name).xcodeproj").path, "-scheme", metadata.name, "-configuration", "Debug", "-derivedDataPath", derivedData.path, "-quiet", "build"]
    status("Building and signing for iOS…")
    var deviceArguments = base + ["-destination", "generic/platform=iOS"]
    if options.provisioningUpdates { deviceArguments.append("-allowProvisioningUpdates") }
    try run("/usr/bin/xcodebuild", deviceArguments, log: cache.appendingPathComponent("device-build.log"))
    let deviceApp = derivedData.appendingPathComponent("Build/Products/Debug-iphoneos/\(metadata.name).app")
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", deviceApp.path], log: nil)
    guard files.fileExists(atPath: deviceApp.appendingPathComponent("embedded.mobileprovision").path) else {
        throw CommandError(message: "Device build has no embedded provisioning profile: \(deviceApp.path)")
    }
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
    try run("/usr/bin/xcodebuild", base + ["-destination", "platform=iOS Simulator,id=\(simulator)", "CODE_SIGNING_ALLOWED=NO"], log: cache.appendingPathComponent("simulator-build.log"))
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
    try emit(["signedDeviceApp": deviceApp.path, "simulatorApp": simulatorApp.path, "simulator": simulator, "screenshot": screenshot.path, "logs": cache.path, "result": "signed-device-build-and-simulator-launch-passed"])
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
        print("""
        uikit-app create <Name> --icon <purpose-or-symbol> --output <new-directory>
          [--team <ID>] [--bundle-id <ID>] [--deployment-target <version>]
        uikit-app check <project-directory> [--simulator <UDID>] [--allow-provisioning-updates]

        Creates from the programmatic UIKit template and integrates an Icon Studio icon.
        check signs a Debug device build, verifies its signature, builds and launches in a simulator,
        captures a screenshot, and restores a simulator it booted to shutdown. Logs stay in Library/Caches.
        check is a startup smoke check; app-specific behavior still needs verification.
        Signing uses cached credentials unless --allow-provisioning-updates is supplied.
        Personal defaults: ~/.config/uikit-app/config.json (team and bundlePrefix).
        """)
    } else {
        guard arguments.count >= 2 else { throw CommandError(message: "Use uikit-app --help") }
        switch arguments[0] {
        case "create":
            try create(name: arguments[1], options: Options(arguments.dropFirst(2), allowed: ["--icon", "--output", "--team", "--bundle-id", "--deployment-target"]))
        case "check":
            try check(directory: arguments[1], options: Options(arguments.dropFirst(2), allowed: ["--simulator", "--allow-provisioning-updates"]))
        default:
            throw CommandError(message: "Unknown command: \(arguments[0]). Use uikit-app --help")
        }
    }
} catch {
    status(error.localizedDescription)
    exit(1)
}
