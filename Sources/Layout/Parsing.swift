import Foundation

/// Text that comes back from other programs (arXiv, folio, rg, the browsers), turned into
/// plain values; the app adds icons and actions.
public enum Parse {
    // MARK: arXiv

    public struct Paper: Equatable, Sendable {
        public var id: String
        public var title: String
        public var authors: [String]
        public var year: String

        public var pdf: URL? { URL(string: "https://arxiv.org/pdf/\(id)") }

        /// Named like folio names its files: `2017-vaswani-attention-is-all-you-need.pdf`.
        public var fileName: String {
            let surname = authors.first?.split(separator: " ").last.map { $0.lowercased() } ?? "arxiv"
            let slug = title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(6).joined(separator: "-")
            return "\(year)-\(surname)-\(slug).pdf"
        }

        public var detail: String {
            ["arXiv", authors.prefix(2).joined(separator: ", ") + (authors.count > 2 ? " et al." : ""), year]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// arXiv finds nothing when a required term is a stopword ("attention is all you need").
    static let stopwords: Set<String> = ["a", "an", "the", "is", "are", "of", "in", "on", "for", "and", "or", "to",
                                         "with", "all", "you", "we", "your", "by", "at", "as", "from", "what", "how",
                                         "be", "it", "its"]

    public static func arxivQuery(_ query: String) -> String {
        query.lowercased().split(separator: " ").filter { !stopwords.contains(String($0)) }
            .map { "all:\($0)" }.joined(separator: " AND ")
    }

    public static func arxiv(_ xml: String) -> [Paper] {
        func field(_ tag: String, in s: Substring) -> String? {
            guard let a = s.range(of: "<\(tag)>"), let b = s.range(of: "</\(tag)>", range: a.upperBound..<s.endIndex) else { return nil }
            return s[a.upperBound..<b.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return xml.components(separatedBy: "<entry>").dropFirst().compactMap { e in
            let entry = Substring(e)
            guard let id = field("id", in: entry)?.components(separatedBy: "/abs/").last, let title = field("title", in: entry)
            else { return nil }
            let authors = entry.components(separatedBy: "<name>").dropFirst().compactMap { $0.components(separatedBy: "</name>").first }
            return Paper(id: id, title: title, authors: authors, year: String(field("published", in: entry)?.prefix(4) ?? ""))
        }
    }

    // MARK: folio

    public struct Book: Equatable, Sendable {
        public var md5: String
        public var title: String
        public var detail: String
        public var ext: String
    }

    /// `folio search --json` output.
    public static func folio(_ json: String) -> [Book] {
        let found = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        return found.compactMap { b in
            guard let md5 = b["md5"] as? String else { return nil }
            let ext = b["ext"] as? String ?? ""
            let detail = [b["author"] as? String, b["year"] as? String, ext, b["size"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return Book(md5: md5, title: b["title"] as? String ?? md5, detail: detail, ext: ext)
        }
    }

    // MARK: rg

    public struct Match: Equatable, Sendable {
        /// Relative to where rg ran.
        public var path: String
        public var line: Int
        public var text: String
    }

    /// One `rg --line-number --no-heading` line: `path:line:text`.
    public static func rg(_ line: Substring) -> Match? {
        let f = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, let n = Int(f[1]) else { return nil }
        return Match(path: f[0].hasPrefix("./") ? String(f[0].dropFirst(2)) : f[0], line: n,
                     text: f[2].trimmingCharacters(in: .whitespaces))
    }

    // MARK: Browsers

    public struct Tab: Equatable, Sendable {
        public var window: Int
        public var index: Int
        public var title: String
        public var url: String
    }

    /// `window id, tab index, title, url`, tab separated (what the tabs AppleScript prints).
    public static func tab(_ line: Substring) -> Tab? {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4, let w = Int(f[0]), let i = Int(f[1]) else { return nil }
        return Tab(window: w, index: i, title: f[2].isEmpty ? f[3] : f[2], url: f[3])
    }

    public struct Page: Equatable, Sendable {
        public var title: String
        public var url: URL
        public var host: String
    }

    /// `title, url`, tab separated (bookmarks and history); only web pages.
    public static func page(_ line: Substring) -> Page? {
        let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 2, let url = URL(string: f[1]), url.scheme?.hasPrefix("http") == true else { return nil }
        return Page(title: f[0].isEmpty ? f[1] : f[0], url: url, host: url.host ?? f[1])
    }

    /// `~/x` for a path under `home`.
    public static func short(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
