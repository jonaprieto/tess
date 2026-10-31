import Foundation
import Testing
@testable import Layout

/// The string after `start`, an opening quote's next index, as `Phrase` keys it: interpolations
/// as `%@`, escapes resolved.
private func key(in source: String, from start: String.Index) -> String {
    var out = ""
    var i = start
    while i < source.endIndex, source[i] != "\"" {
        guard source[i] == "\\" else {
            out.append(source[i])
            i = source.index(after: i)
            continue
        }
        let escaped = source[source.index(after: i)]
        i = source.index(i, offsetBy: 2)
        guard escaped == "(" else {
            out.append(escaped == "n" ? "\n" : escaped)
            continue
        }
        out += "%@"
        var depth = 1, quoted = false
        while depth > 0 {
            if source[i] == "\"" { quoted.toggle() }
            if !quoted { depth += source[i] == "(" ? 1 : source[i] == ")" ? -1 : 0 }
            i = source.index(after: i)
        }
    }
    return out
}

/// Every `L("...")` in Sources.
private func phrases() throws -> Set<String> {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
    var found: Set<String> = []
    for case let url as URL in sources! where url.pathExtension == "swift" && url.lastPathComponent != "Spanish.swift" {
        let source = try String(contentsOf: url, encoding: .utf8)
        var rest = source.startIndex..<source.endIndex
        while let call = source.range(of: "L(\"", range: rest) {
            rest = call.upperBound..<source.endIndex
            let before = call.lowerBound == source.startIndex ? " " : source[source.index(before: call.lowerBound)]
            if !before.isLetter, !before.isNumber, before != "." { found.insert(key(in: source, from: call.upperBound)) }
        }
    }
    return found
}

@Test func everyPhraseHasItsSpanishAndNoMore() throws {
    let used = try phrases()
    #expect(used.subtracting(spanish.keys).sorted() == [])
    #expect(Set(spanish.keys).subtracting(used).sorted() == [])
    for (english, translated) in spanish {
        #expect(english.components(separatedBy: "%@").count == translated.components(separatedBy: "%@").count, "\(english)")
    }
}

@Test func valuesLandInPlaceAndWhatHasNoEntryStaysEnglish() {
    let n = 2
    let move: Phrase = "Move to screen \(n)"
    #expect(move.text(in: .en) == "Move to screen 2")
    let unknown: Phrase = "not in the table \(n) at all"
    #expect(unknown.text(in: .es) == "not in the table 2 at all")
    let percent: Phrase = "Volume \(n)%"
    #expect(percent.text(in: .en) == "Volume 2%")
}

@Test func theLanguageIsTheFirstOfMacOSsThatTessSpeaks() throws {
    #expect(Language.first(of: ["en-NO", "es-419"]) == .en)
    #expect(Language.first(of: ["nb-NO", "es-419", "en"]) == .es)
    #expect(Language.first(of: ["nb-NO"]) == .en)
    #expect(try Config.load(Data(#"{"language": "es"}"#.utf8)).language == .es)
    #expect(throws: ParseError.self) { try Config.load(Data(#"{"language": "fr"}"#.utf8)) }
}
