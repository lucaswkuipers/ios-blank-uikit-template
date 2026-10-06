import Foundation
import Darwin

do {
    if CommandLine.arguments.dropFirst() == ["--prompt"] {
        guard isatty(STDIN_FILENO) == 1, tcgetpgrp(STDIN_FILENO) == getpgrp() else {
            throw CommandError(message: "Login helper lost foreground terminal ownership.")
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw CommandError(message: "Cannot inspect terminal input mode.")
        }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else {
            throw CommandError(message: "Cannot enable hidden terminal input.")
        }
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        status("Dummy password prompt ready (local test only):")
        guard readLine() == "dummy-local-input" else {
            throw CommandError(message: "Interactive input did not reach the login helper.")
        }
    } else {
        try runInteractive(Bundle.main.executableURL!.path, arguments: ["--prompt"], environment: ProcessInfo.processInfo.environment)
        print("Passed foreground terminal ownership and hidden-input delivery.")
    }
} catch {
    status(error.localizedDescription)
    exit(1)
}
