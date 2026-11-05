import Foundation
import SiestaCore

/// Everything a command needs, built once in main from the paths and the config file.
struct Context {
    let paths: Paths
    let config: Config
    let runner: Shell
    let backend: ColimaBackend
    let store: FileStateStore
    let agent: LaunchAgent
    let output: Output

    init(paths: Paths, config: Config, output: Output) {
        self.paths = paths
        self.config = config
        self.output = output
        runner = Shell(binPaths: config.binPaths, home: paths.home)
        backend = ColimaBackend(runner: runner, paths: paths)
        store = FileStateStore(url: paths.stateFile)
        agent = LaunchAgent(paths: paths, runner: runner, binPaths: runner.binPaths)
    }

    func logger(echo: Bool) -> FileLogger { FileLogger(file: paths.logFile, echo: echo) }

    func checker(dryRun: Bool, echo: Bool) -> Checker {
        Checker(config: config, backend: backend, store: store, log: logger(echo: echo), lockFile: paths.lockFile, dryRun: dryRun)
    }

    /// The profiles this install watches, per the config.
    func watchedProfiles() throws -> [ProfileInfo] {
        let all = try backend.profiles()
        return config.profiles.isEmpty ? all : all.filter { config.profiles.contains($0.name) }
    }
}

/// Where command output goes. Rows are aligned "label   value" lines, the same shape in every command.
struct Output {
    private let labelWidth = 12

    func line(_ text: String = "") { print(text) }
    func row(_ label: String, _ value: String) { print(label.padding(toLength: labelWidth, withPad: " ", startingAt: 0) + " " + value) }
    func raw(_ data: Data) { FileHandle.standardOutput.write(data) }
}
