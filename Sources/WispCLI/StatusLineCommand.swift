import Darwin
import Foundation
import WispCore

/// `wisp statusline --folder <claude config folder> [--then <command>]`
///
/// Saves the plan limits from Claude Code's status-line input, then runs the status
/// line that was there before with the same input and passes on what it prints.
enum StatusLineCommand {
    static func run(_ args: [String]) -> Never {
        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let folder = value("--folder") ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        ClaudeStatusLine.record(input: input, folder: folder)
        guard let original = value("--then"), !original.isEmpty else { exit(0) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", original]
        let pipe = Pipe()
        task.standardInput = pipe
        guard (try? task.run()) != nil else { exit(1) }
        // The other status line may not read its input; ignore a closed pipe.
        signal(SIGPIPE, SIG_IGN)
        try? pipe.fileHandleForWriting.write(contentsOf: input)
        try? pipe.fileHandleForWriting.close()
        task.waitUntilExit()
        exit(task.terminationStatus)
    }
}
