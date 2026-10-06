import Foundation

struct PersonalRepository: Decodable {
    let nameWithOwner: String
    let isPrivate: Bool
    let url: String

    func verify(name: String) throws {
        guard nameWithOwner.lowercased() == "lucaswkuipers/\(name)".lowercased(), isPrivate else {
            throw CommandError(message: "Expected private repository lucaswkuipers/\(name). No source will be pushed.")
        }
    }
}

struct PersonalGitHub {
    static let executable = "/opt/homebrew/bin/gh"
    let baseEnvironment: [String: String]
    let environment: [String: String]

    init() throws {
        var base = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("GIT_") && !$0.key.hasPrefix("GH_") && !$0.key.hasPrefix("GITHUB_")
        }
        base["GH_HOST"] = "github.com"
        base["GH_PROMPT_DISABLED"] = "1"
        base["GIT_TERMINAL_PROMPT"] = "0"
        try Self.verifyActiveAccount(environment: base)
        let token = try run(Self.executable, ["auth", "token", "--hostname", "github.com", "--user", "lucaswkuipers"], log: nil, environment: base)
        var authenticated = base
        authenticated["GH_TOKEN"] = token
        baseEnvironment = base
        environment = authenticated
    }

    static func verifyActiveAccount(environment: [String: String]) throws {
        let arguments = ["auth", "status", "--hostname", "github.com", "--active", "--json", "hosts", "--jq", ".hosts[\"github.com\"][] | select(.active and .state == \"success\") | .login"]
        if try run(executable, arguments, log: nil, environment: environment) == "lucaswkuipers" {
            return
        }
        try run(executable, ["auth", "switch", "--hostname", "github.com", "--user", "lucaswkuipers"], log: nil, environment: environment)
        guard try run(executable, arguments, log: nil, environment: environment) == "lucaswkuipers" else {
            throw CommandError(message: "Personal GitHub login lucaswkuipers is required.")
        }
    }

    @discardableResult
    func call(_ arguments: [String]) throws -> String {
        try Self.verifyActiveAccount(environment: baseEnvironment)
        return try run(Self.executable, arguments, log: nil, environment: environment, separateError: true)
    }

    @discardableResult
    func git(_ root: URL, _ arguments: [String], remote: Bool) throws -> String {
        if remote {
            try Self.verifyActiveAccount(environment: baseEnvironment)
        }
        return try run("/usr/bin/git", ["-C", root.path] + arguments, log: nil, environment: baseEnvironment, separateError: true)
    }

    func repository(name: String) throws -> PersonalRepository {
        let output = try call(["repo", "view", "lucaswkuipers/\(name)", "--json", "nameWithOwner,isPrivate,url"])
        let repository = try JSONDecoder().decode(PersonalRepository.self, from: Data(output.utf8))
        try repository.verify(name: name)
        return repository
    }
}

func verifyPersonalRemote(_ remote: String, name: String) throws {
    let path = "lucaswkuipers/\(name).git"
    let allowed = ["git@github.com-personal:\(path)", "git@github.com:\(path)", "https://github.com/\(path)", "https://github.com/lucaswkuipers/\(name)"]
    guard allowed.contains(where: { $0.lowercased() == remote.lowercased() }) else {
        throw CommandError(message: "Origin must belong to lucaswkuipers/\(name). Existing remote was not changed.")
    }
}

func setupAppRepository(directory: String, template: URL) throws -> PersonalRepository {
    let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
    let metadata = try JSONDecoder().decode(Project.self, from: Data(contentsOf: root.appendingPathComponent(".uikit-app.json")))
    try validate(metadata.name, pattern: "^[A-Za-z][A-Za-z0-9]*$", label: "project name")
    guard metadata.bundleIdentifier.hasPrefix(TestFlightConfiguration.bundlePrefix) else {
        throw CommandError(message: "Automatic repositories are for Lucas's personal apps. Use --local-only for other projects.")
    }
    let github = try PersonalGitHub()
    if !files.fileExists(atPath: root.appendingPathComponent(".git").path) {
        try github.git(root, ["init", "-b", "main"], remote: false)
    }
    guard try URL(fileURLWithPath: github.git(root, ["rev-parse", "--show-toplevel"], remote: false)).resolvingSymlinksInPath() == root,
          try github.git(root, ["symbolic-ref", "--short", "HEAD"], remote: false) == "main" else {
        throw CommandError(message: "Repository setup requires this app's own checkout on main.")
    }
    try github.git(root, ["config", "user.name", "Lucas Werner Kuipers"], remote: false)
    try github.git(root, ["config", "user.email", "lucaswkuipers@gmail.com"], remote: false)
    let remotes = try github.git(root, ["remote"], remote: false).split(separator: "\n")
    if remotes.contains("origin") {
        try verifyPersonalRemote(github.git(root, ["remote", "get-url", "origin"], remote: false), name: metadata.name)
    } else {
        try github.call(["repo", "create", "lucaswkuipers/\(metadata.name)", "--private", "--source", root.path, "--remote", "origin"])
    }
    let repository = try github.repository(name: metadata.name)
    try github.git(root, ["remote", "set-url", "origin", "git@github.com-personal:lucaswkuipers/\(metadata.name).git"], remote: false)
    let workflowPath = ".github/workflows/\(metadata.route.workflow)"
    let workflow = root.appendingPathComponent(workflowPath)
    let createdWorkflow = !files.fileExists(atPath: workflow.path)
    if createdWorkflow {
        try files.createDirectory(at: workflow.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = metadata.route == .shelf ? "testflight.yml" : "shelf.yml"
        guard !files.fileExists(atPath: root.appendingPathComponent(".github/workflows/\(other)").path) else {
            throw CommandError(message: "This app already has another delivery workflow. Migrate its push trigger before adding a second route to avoid duplicate builds.")
        }
        try files.copyItem(at: template.appendingPathComponent("CLI/\(metadata.route.workflow)"), to: workflow)
    }
    if (try? github.git(root, ["rev-parse", "--verify", "HEAD"], remote: false)) == nil {
        try github.git(root, ["add", "--all"], remote: false)
        try github.git(root, ["commit", "-m", "Create \(metadata.name) [skip ci]"], remote: false)
    } else if createdWorkflow {
        try github.git(root, ["add", workflowPath], remote: false)
        try github.git(root, ["commit", "--only", workflowPath, "-m", "Enable personal \(metadata.route.rawValue) delivery [skip ci]"], remote: false)
    }
    try github.git(root, ["push", "-u", "origin", "main"], remote: true)
    try installRunner(name: metadata.name, github: github)
    return repository
}
