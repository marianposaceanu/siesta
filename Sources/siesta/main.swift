import Foundation
import SiestaCore

/// Entry point: build the context, find the command, run it, map failures to exit codes.
func main() -> Int32 {
    let args = Arguments(Array(CommandLine.arguments.dropFirst()))
    let paths = Paths()
    let stderr = FileHandle.standardError
    do {
        let config = try Config.load(from: paths.configFile)
        let context = Context(paths: paths, config: config, output: Output())
        guard let command = Commands.named(args.command) else {
            try HelpCommand().run(context, args)
            return args.command == "help" ? 0 : 64
        }
        try command.init().run(context, args)
        return 0
    } catch let failure as CommandFailure {
        stderr.write(Data("siesta: \(failure)\n".utf8))
        return 1
    } catch {
        stderr.write(Data("siesta: \(error)\n".utf8))
        return 2
    }
}

exit(main())
