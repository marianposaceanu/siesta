import Foundation

/// One place for how siesta's JSON files are read and written: ISO 8601 dates, stable key order,
/// readable slashes, atomic writes, and a missing file reported as nil rather than an error.
public enum JSONFile {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(T.self, from: try Data(contentsOf: url))
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    public static func render<T: Encodable>(_ value: T) -> String {
        String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
