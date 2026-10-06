import CryptoKit
import Foundation

func installRunner(name: String, github: PersonalGitHub) throws {
    let storage = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/uikit-app")
    let runner = storage.appendingPathComponent("runners/\(name)")
    try files.createDirectory(at: runner, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if !files.fileExists(atPath: runner.appendingPathComponent("config.sh").path) {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
                let digest: String?
            }
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: Data(github.call(["api", "repos/actions/runner/releases/latest"]).utf8))
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("actions-runner-osx-arm64-") && $0.name.hasSuffix(".tar.gz") }),
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              asset.browser_download_url.hasPrefix("https://github.com/actions/runner/releases/download/") else {
            throw CommandError(message: "Cannot find a verified Apple Silicon GitHub runner release.")
        }
        let package = storage.appendingPathComponent(asset.name)
        if !files.fileExists(atPath: package.path) {
            status("Downloading GitHub's Mac runner…")
            let temporary = package.appendingPathExtension("download")
            defer { try? files.removeItem(at: temporary) }
            try run("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--max-time", "300", asset.browser_download_url, "--output", temporary.path], log: nil)
            let checksum = SHA256.hash(data: try Data(contentsOf: temporary)).map { String(format: "%02x", $0) }.joined()
            guard "sha256:\(checksum)" == digest else {
                throw CommandError(message: "GitHub runner download checksum does not match.")
            }
            try files.moveItem(at: temporary, to: package)
        }
        let checksum = SHA256.hash(data: try Data(contentsOf: package)).map { String(format: "%02x", $0) }.joined()
        guard "sha256:\(checksum)" == digest else {
            throw CommandError(message: "Cached GitHub runner checksum does not match.")
        }
        try run("/usr/bin/tar", ["-xzf", package.path, "-C", runner.path], log: nil)
    }
    if !files.fileExists(atPath: runner.appendingPathComponent(".runner").path) {
        struct Registration: Decodable { let token: String }
        let registration = try JSONDecoder().decode(Registration.self, from: Data(github.call(["api", "--method", "POST", "repos/lucaswkuipers/\(name)/actions/runners/registration-token"]).utf8))
        status("Registering the personal Mac runner for \(name)…")
        try run("/usr/bin/env", ["-C", runner.path, "./config.sh", "--unattended", "--url", "https://github.com/lucaswkuipers/\(name)", "--token", registration.token, "--name", "uikit-app-\(name)", "--labels", "uikit-app-personal", "--work", "_work"], log: nil, environment: github.baseEnvironment)
    }
    let serviceFile = runner.appendingPathComponent(".service")
    if !files.fileExists(atPath: serviceFile.path) {
        try run("/usr/bin/env", ["-C", runner.path, "./svc.sh", "install"], log: nil, environment: github.baseEnvironment)
    }
    let servicePath = try String(contentsOf: serviceFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard var service = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: servicePath)), format: nil) as? [String: Any],
          let label = service["Label"] as? String else {
        throw CommandError(message: "Cannot read the GitHub runner launch service.")
    }
    let domain = "gui/\(getuid())"
    var loaded = (try? run("/bin/launchctl", ["print", "\(domain)/\(label)"], log: nil)) != nil
    if service["SessionCreate"] as? Bool == true {
        let busy = try github.call(["api", "repos/lucaswkuipers/\(name)/actions/runners", "--jq", ".runners[] | select(.name == \"uikit-app-\(name)\") | .busy"])
        guard busy != "true" else {
            throw CommandError(message: "Wait for the current delivery before updating the runner's signing session, then rerun setup-repo.")
        }
        // Signing must share the logged-in user's unlocked keychain security session.
        service.removeValue(forKey: "SessionCreate")
        try PropertyListSerialization.data(fromPropertyList: service, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: servicePath), options: .atomic)
        if loaded {
            try run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], log: nil)
            loaded = false
        }
    }
    if !loaded {
        // bootout can return before launchd finishes removing the previous service.
        for attempt in 0..<10 {
            do {
                try run("/bin/launchctl", ["bootstrap", domain, servicePath], log: nil)
                break
            } catch {
                if attempt == 9 { throw error }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }
    try run("/bin/launchctl", ["kickstart", "\(domain)/\(label)"], log: nil)
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        let online = try github.call(["api", "repos/lucaswkuipers/\(name)/actions/runners", "--jq", ".runners[] | select(.name == \"uikit-app-\(name)\") | .status"])
        if online == "online" {
            return
        }
        Thread.sleep(forTimeInterval: 2)
    }
    throw CommandError(message: "GitHub runner is not online yet. Inspect \(runner.path)/_diag and rerun setup-repo.")
}

struct DeliveryRun: Decodable {
    let databaseId: Int
    let status: String
    let conclusion: String
    let url: String
}

func skipsPushWorkflow(_ message: String) -> Bool {
    ["[skip ci]", "[ci skip]", "[no ci]", "[skip actions]", "[actions skip]"].contains { message.lowercased().contains($0) }
}

func deliveryResult(logs: String, project: Project) -> [String: String]? {
    for line in logs.split(separator: "\n").reversed() {
        guard let start = line.firstIndex(of: "{"),
              let result = try? JSONDecoder().decode([String: String].self, from: Data(line[start...].utf8)),
              result["result"] == project.route.successResult, result["sourcesChanged"] == "false",
              result["team"] == TestFlightConfiguration.personalTeam, result["app"] == project.name,
              let build = result["build"], build.range(of: "^[0-9]{1,4}(?:\\.[0-9]{1,2}){0,2}$", options: .regularExpression) != nil else {
            continue
        }
        return result
    }
    return nil
}

func publish(directory: String) throws {
    let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
    let metadata = try JSONDecoder().decode(Project.self, from: Data(contentsOf: root.appendingPathComponent(".uikit-app.json")))
    try validate(metadata.name, pattern: "^[A-Za-z][A-Za-z0-9]*$", label: "project name")
    let locks = TestFlightConfiguration.directory.appendingPathComponent("locks")
    try files.createDirectory(at: locks, withIntermediateDirectories: true)
    let descriptor = open(locks.appendingPathComponent("publish-\(metadata.name).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw CommandError(message: "Cannot open publish lock.")
    }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw CommandError(message: "Another publish command is already waiting for this app. Follow that command instead of starting another delivery.")
    }
    let github = try PersonalGitHub()
    let repository = try github.repository(name: metadata.name)
    try verifyPersonalRemote(github.git(root, ["remote", "get-url", "origin"], remote: false), name: metadata.name)
    guard try github.git(root, ["symbolic-ref", "--short", "HEAD"], remote: false) == "main",
          try github.git(root, ["status", "--porcelain"], remote: false).isEmpty else {
        throw CommandError(message: "Review and commit the app changes on main before publishing.")
    }
    let commit = try github.git(root, ["rev-parse", "HEAD"], remote: false)
    let skippedPush = skipsPushWorkflow(try github.git(root, ["log", "-1", "--format=%B"], remote: false))
    try github.git(root, ["remote", "set-url", "origin", "git@github.com-personal:lucaswkuipers/\(metadata.name).git"], remote: false)
    try github.git(root, ["push", "origin", "main"], remote: true)
    status("Waiting for GitHub's \(metadata.route.rawValue) delivery of \(commit.prefix(7))…")
    let deadline = Date().addingTimeInterval(3000)
    var registrationDeadline = Date().addingTimeInterval(skippedPush ? 0 : 90)
    var dispatched = false
    var previousStatus = ""
    while Date() < deadline {
        let output = try github.call(["run", "list", "--repo", repository.nameWithOwner, "--workflow", metadata.route.workflow, "--commit", commit, "--json", "databaseId,status,conclusion,url", "--limit", "1"])
        let runs = try JSONDecoder().decode([DeliveryRun].self, from: Data(output.utf8))
        if let delivery = runs.first {
            if delivery.status != previousStatus {
                status("GitHub delivery: \(delivery.status) — \(delivery.url)")
                previousStatus = delivery.status
            }
            if delivery.status == "completed" {
                guard delivery.conclusion == "success" else {
                    throw CommandError(message: "Delivery workflow finished with \(delivery.conclusion): \(delivery.url). Fix or rerun this workflow; the CLI retains resumable delivery state.")
                }
                let logs = try github.call(["run", "view", String(delivery.databaseId), "--repo", repository.nameWithOwner, "--log"])
                if let result = deliveryResult(logs: logs, project: metadata) {
                    try emit(result.merging(["repository": repository.url, "workflow": delivery.url, "commit": commit], uniquingKeysWith: { _, new in new }))
                    return
                }
                throw CommandError(message: "Workflow succeeded but did not confirm personal \(metadata.route.rawValue) availability: \(delivery.url)")
            }
        } else if Date() > registrationDeadline {
            guard !dispatched else {
                throw RequiredAction(result: "delivery-pending", message: "GitHub accepted the workflow dispatch but has not listed it yet. Do not dispatch another run.", command: "uikit-app publish \(root.path)")
            }
            let currentMain = try github.call(["api", "repos/\(repository.nameWithOwner)/git/ref/heads/main", "--jq", ".object.sha"])
            guard currentMain == commit else {
                throw CommandError(message: "Main advanced while waiting. Publish the current main commit instead of dispatching an older build.")
            }
            status("Starting the missing \(metadata.route.rawValue) workflow for this commit…")
            try github.call(["workflow", "run", metadata.route.workflow, "--repo", repository.nameWithOwner, "--ref", "main"])
            dispatched = true
            registrationDeadline = Date().addingTimeInterval(90)
        }
        Thread.sleep(forTimeInterval: 10)
    }
    try emit(["result": "delivery-pending", "repository": repository.url, "commit": commit, "resume": "uikit-app publish \(root.path)"])
}
