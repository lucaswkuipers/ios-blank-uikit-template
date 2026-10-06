import Foundation

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
    var provisioningUpdates = false
    var retryUpload = false

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
