import Foundation

/// The languages tess speaks.
public enum Language: String, CaseIterable, Sendable {
    case en, es

    /// The first of `preferred` (macOS's list, like `es-419`) that tess speaks, else English.
    public static func first(of preferred: [String]) -> Language {
        preferred.lazy.compactMap { Language(rawValue: String($0.prefix(2))) }.first ?? .en
    }
}

/// A piece of the interface as written in English where it is used. That text, with `%@` for
/// each interpolation, is its key in `spanish`; what has no entry stays English. Interpolated
/// values go in as they are, in order, so a word that varies is written out once per value.
public struct Phrase: ExpressibleByStringInterpolation, Sendable {
    let key: String
    let values: [String]

    public init(stringLiteral value: String) {
        key = value
        values = []
    }

    public init(stringInterpolation i: Interpolation) {
        key = i.key
        values = i.values
    }

    public struct Interpolation: StringInterpolationProtocol, Sendable {
        var key = ""
        var values: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) { key += literal }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            values.append("\(value)")
        }
    }

    public func text(in language: Language) -> String {
        let template = language == .es ? spanish[key] ?? key : key
        let parts = template.components(separatedBy: "%@")
        return zip(parts, values + Array(repeating: "", count: parts.count)).map { $0 + $1 }.joined()
    }
}

public enum Strings {
    /// Set from the config; a test asks `Phrase.text(in:)` instead.
    nonisolated(unsafe) public static var language = Language.en
}

/// `phrase` in the current language.
public func L(_ phrase: Phrase) -> String { phrase.text(in: Strings.language) }
