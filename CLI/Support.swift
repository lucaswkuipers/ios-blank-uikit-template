import Foundation
import Darwin

let files = FileManager.default

struct Project: Codable {
    let name: String
    let bundleIdentifier: String
}


struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Options {
    var values: [String: String] = [:]
    var retryUpload = false

    init(_ arguments: ArraySlice<String>, allowed: Set<String>) throws {
        var remaining = Array(arguments)
        while !remaining.isEmpty {
            let key = remaining.removeFirst()
            guard allowed.contains(key) else {
                throw CommandError(message: "Unknown option: \(key)")
            }
            if key == "--retry-upload" {
                retryUpload = true
                continue
            }
            guard !remaining.isEmpty, !remaining[0].hasPrefix("--"), values[key] == nil else {
                throw CommandError(message: "Provide one value for \(key)")
            }
            values[key] = remaining.removeFirst()
        }
    }
}

func status(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func runInteractive(_ executable: String, arguments: [String], environment: [String: String]) throws {
    let argumentPointers = ([executable] + arguments).map { strdup($0) } + [nil]
    let environmentPointers = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argumentPointers.forEach { free($0) }
        environmentPointers.forEach { free($0) }
    }
    var processID = pid_t()
    let launchResult = argumentPointers.withUnsafeBufferPointer { arguments in
        environmentPointers.withUnsafeBufferPointer { environment in
            posix_spawn(&processID, executable, nil, nil, arguments.baseAddress!, environment.baseAddress!)
        }
    }
    guard launchResult == 0 else {
        throw CommandError(message: "Cannot launch interactive sign-in: \(String(cString: strerror(launchResult)))")
    }
    var terminationStatus = Int32()
    while waitpid(processID, &terminationStatus, 0) == -1 {
        guard errno == EINTR else {
            throw CommandError(message: "Cannot wait for interactive sign-in: \(String(cString: strerror(errno)))")
        }
    }
    guard terminationStatus == 0 else {
        throw CommandError(message: "Interactive sign-in failed. See the login helper's message above; no password is recorded in the CLI output.")
    }
}

@discardableResult
func run(_ executable: String, _ arguments: [String], log: URL?, environment: [String: String]? = nil, separateError: Bool = false) throws -> String {
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
    process.environment = environment
    if executable == "/usr/bin/xcodebuild" {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        process.environment = environment
    }
    process.standardOutput = handle
    let errorOutput = output.appendingPathExtension("stderr")
    let errorHandle: FileHandle?
    if separateError {
        files.createFile(atPath: errorOutput.path, contents: nil)
        errorHandle = try FileHandle(forWritingTo: errorOutput)
    } else { errorHandle = nil }
    defer {
        try? errorHandle?.close()
        if log == nil { try? files.removeItem(at: errorOutput) }
    }
    process.standardError = errorHandle ?? handle
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let text = try String(contentsOf: output, encoding: .utf8)
    guard process.terminationStatus == 0 else {
        let errors = separateError ? ((try? String(contentsOf: errorOutput, encoding: .utf8)) ?? "") : ""
        let tail = (text + errors).split(separator: "\n").suffix(18).joined(separator: "\n")
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
