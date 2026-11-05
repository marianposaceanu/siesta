/// Minimal argument parsing: the first word is the command, `--flag` and `-x` are flags,
/// `-n 5` style pairs are options, everything else is positional. No dependency needed for this.
struct Arguments {
    let command: String
    let positional: [String]
    private let flags: Set<String>
    private let options: [String: String]

    private static let valued: Set<String> = ["-n"]

    init(_ argv: [String]) {
        var words = argv[...]
        // `siesta --force` and `siesta --dry-run` are shorthand for the check command.
        command = words.first.map { $0.hasPrefix("-") } == true ? "check" : (words.popFirst() ?? "help")
        var positional: [String] = [], flags = Set<String>(), options: [String: String] = [:]
        while let word = words.popFirst() {
            if Arguments.valued.contains(word), let value = words.popFirst() { options[word] = value }
            else if word.hasPrefix("-") { flags.insert(word) }
            else { positional.append(word) }
        }
        self.positional = positional; self.flags = flags; self.options = options
    }

    func has(_ flag: String...) -> Bool { flag.contains(where: flags.contains) }
    func value(_ option: String) -> String? { options[option] }
    func int(_ option: String, default fallback: Int) -> Int { options[option].flatMap(Int.init) ?? fallback }
}
