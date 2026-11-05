import Foundation
import SiestaCore

/// One subcommand. Each is a small type; `main` looks them up by name.
protocol Command {
    static var name: String { get }
    static var usage: String { get }
    static var summary: String { get }
    init()
    func run(_ context: Context, _ args: Arguments) throws
}

/// A command that stops with a message and a non-zero exit, without being an internal failure.
struct CommandFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

enum Commands {
    static var all: [any Command.Type] { [
        CheckCommand.self, StatusCommand.self, LogsCommand.self, StopCommand.self, PauseCommand.self,
        InstallCommand.self, UninstallCommand.self, RunNowCommand.self, ConfigCommand.self,
        DoctorCommand.self, VersionCommand.self, HelpCommand.self,
    ] }

    static func named(_ name: String) -> (any Command.Type)? {
        all.first { $0.name == name } ?? (name == "--version" ? VersionCommand.self : nil)
    }
}
