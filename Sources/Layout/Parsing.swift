import Foundation

/// Text that comes back from other programs (arXiv, folio, rg, the
/// browsers), turned into plain values; the app adds icons and
/// actions. tess's own picker searches, which a verb names as its
/// value: `"file": "search:files"`.
public enum PickerSearch: String, CaseIterable, Sendable {
  /// File names (Spotlight), text in files (ripgrep), books and
  /// papers (folio, papers also on arXiv).
  case files, text, books, papers
  /// Only the pages the picker has from browsers (tabs, bookmarks,
  /// history), and an address to open when the text is one.
  case history

  /// The search a verb's value names; nil for an app or a link.
  public init?(verb value: String) {
    guard value.hasPrefix("search:") else { return nil }
    self.init(rawValue: String(value.dropFirst(7)))
  }
}

/// A verb whose value is `keys:Slack:cmd-k`: the app in front, the
/// shortcut pressed, then the text typed, for an app's own switcher
/// or search.
public struct KeysVerb: Equatable, Sendable {
  public var app: String
  public var key: KeySpec

  public init?(verb value: String) {
    let parts = value.split(separator: ":", maxSplits: 2).map(
      String.init)
    guard parts.count == 3, parts[0] == "keys", !parts[1].isEmpty,
      let key = try? KeySpec.parse(parts[2])
    else { return nil }
    app = parts[1]
    self.key = key
  }
}

public enum Parse {
  // MARK: arXiv

  public struct Paper: Equatable, Sendable {
    public var id: String
    public var title: String
    public var authors: [String]
    public var year: String

    public var pdf: URL? {
      URL(string: "https://arxiv.org/pdf/\(id)")
    }

    /// Named like folio names its files:
    /// `2017-vaswani-attention-is-all-you-need.pdf`.
    public var fileName: String {
      let surname =
        authors.first?.split(separator: " ").last.map {
          $0.lowercased()
        } ?? "arxiv"
      let slug = title.lowercased().split {
        !$0.isLetter && !$0.isNumber
      }.prefix(6).joined(separator: "-")
      return "\(year)-\(surname)-\(slug).pdf"
    }

    public var detail: String {
      [
        "arXiv",
        authors.prefix(2).joined(separator: ", ")
          + (authors.count > 2 ? " et al." : ""), year
      ]
      .filter { !$0.isEmpty }.joined(separator: " · ")
    }
  }

  /// arXiv finds nothing when a required term is a stopword
  /// ("attention is all you need").
  static let stopwords: Set<String> = [
    "a", "an", "the", "is", "are", "of", "in", "on", "for", "and",
    "or", "to",
    "with", "all", "you", "we", "your", "by", "at", "as", "from",
    "what", "how",
    "be", "it", "its"
  ]

  public static func arxivQuery(_ query: String) -> String {
    query.lowercased().split(separator: " ").filter {
      !stopwords.contains(String($0))
    }
    .map { "all:\($0)" }.joined(separator: " AND ")
  }

  public static func arxiv(_ xml: String) -> [Paper] {
    func field(_ tag: String, in s: Substring) -> String? {
      guard let a = s.range(of: "<\(tag)>"),
        let b = s.range(
          of: "</\(tag)>", range: a.upperBound..<s.endIndex)
      else { return nil }
      return s[a.upperBound..<b.lowerBound].split(
        whereSeparator: \.isWhitespace
      ).joined(separator: " ")
    }
    return xml.components(separatedBy: "<entry>").dropFirst()
      .compactMap { e in
        let entry = Substring(e)
        guard
          let id = field("id", in: entry)?.components(
            separatedBy: "/abs/"
          ).last, let title = field("title", in: entry)
        else { return nil }
        let authors = entry.components(separatedBy: "<name>")
          .dropFirst().compactMap {
            $0.components(separatedBy: "</name>").first
          }
        return Paper(
          id: id, title: title, authors: authors,
          year: String(field("published", in: entry)?.prefix(4) ?? "")
        )
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
    let found =
      (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
      as? [[String: Any]] ?? []
    return found.compactMap { b in
      guard let md5 = b["md5"] as? String else { return nil }
      let ext = b["ext"] as? String ?? ""
      let detail = [
        b["author"] as? String, b["year"] as? String, ext,
        b["size"] as? String
      ]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(
        separator: " · ")
      return Book(
        md5: md5, title: b["title"] as? String ?? md5, detail: detail,
        ext: ext)
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
    let f = line.split(
      separator: ":", maxSplits: 2, omittingEmptySubsequences: false
    ).map(String.init)
    guard f.count == 3, let n = Int(f[1]) else { return nil }
    return Match(
      path: f[0].hasPrefix("./") ? String(f[0].dropFirst(2)) : f[0],
      line: n,
      text: f[2].trimmingCharacters(in: .whitespaces))
  }

  // MARK: Browsers

  public struct Tab: Equatable, Sendable {
    public var window: Int
    public var index: Int
    public var title: String
    public var url: String
  }

  /// `window id, tab index, title, url`, tab separated (what the tabs
  /// AppleScript prints).
  public static func tab(_ line: Substring) -> Tab? {
    let f = line.split(
      separator: "\t", omittingEmptySubsequences: false
    ).map(String.init)
    guard f.count >= 4, let w = Int(f[0]), let i = Int(f[1]) else {
      return nil
    }
    return Tab(
      window: w, index: i, title: f[2].isEmpty ? f[3] : f[2],
      url: f[3])
  }

  public struct Page: Equatable, Sendable {
    public var title: String
    public var url: URL
    public var host: String
  }

  /// `title, url`, tab separated (bookmarks and history); only web
  /// pages.
  public static func page(_ line: Substring) -> Page? {
    let f = line.split(
      separator: "\t", maxSplits: 1, omittingEmptySubsequences: false
    ).map(String.init)
    guard f.count == 2, let url = URL(string: f[1]),
      url.scheme?.hasPrefix("http") == true
    else { return nil }
    return Page(
      title: f[0].isEmpty ? f[1] : f[0], url: url,
      host: url.host ?? f[1])
  }

  /// `~/x` for a path under `home`.
  public static func short(_ path: String, home: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  /// `2 * (3 + 4)`: + - * / % ^ and parentheses on numbers (the
  /// picker's calculator); nil for anything else, and for a result
  /// that is not a number (a division by zero).
  public static func arithmetic(_ text: String) -> Double? {
    var s = Substring(text.filter { !$0.isWhitespace })
    func eat(_ ops: String) -> Character? {
      guard let c = s.first, ops.contains(c) else { return nil }
      s = s.dropFirst()
      return c
    }
    func primary() -> Double? {
      if eat("(") != nil {
        guard let v = sum(), eat(")") != nil else { return nil }
        return v
      }
      let digits = s.prefix {
        $0.isASCII && ($0.isNumber || $0 == ".")
      }
      s = s.dropFirst(digits.count)
      return Double(digits)
    }
    // `^` binds tightest and to the right; `-2^2` is -4.
    func unary() -> Double? {
      if eat("-") != nil { return unary().map { -$0 } }
      guard let b = primary() else { return nil }
      guard eat("^") != nil else { return b }
      return unary().map { pow(b, $0) }
    }
    func product() -> Double? {
      guard var v = unary() else { return nil }
      while let op = eat("*/%") {
        guard let r = unary() else { return nil }
        v =
          op == "*"
          ? v * r
          : op == "/" ? v / r : v.truncatingRemainder(dividingBy: r)
      }
      return v
    }
    func sum() -> Double? {
      guard var v = product() else { return nil }
      while let op = eat("+-") {
        guard let r = product() else { return nil }
        v = op == "+" ? v + r : v - r
      }
      return v
    }
    guard let v = sum(), s.isEmpty, v.isFinite else { return nil }
    return v
  }

  /// A result as the calculator shows it: whole numbers without a
  /// point, the rest to 12 digits.
  public static func number(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e15
      ? String(Int(v)) : String(format: "%.12g", v)
  }

  /// Text that is a web address: `https://x.y/z` as it is, `x.y/z`
  /// with https in front. Not text with spaces, nor a host without a
  /// dot.
  public static func address(_ text: String) -> URL? {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, !t.contains(" ") else { return nil }
    guard
      let url = URL(string: t.contains("://") ? t : "https://" + t),
      url.scheme == "https" || url.scheme == "http",
      let host = url.host, host.contains("."), !host.hasPrefix("."),
      !host.hasSuffix(".")
    else { return nil }
    return url
  }

  /// The Wi-Fi device in `networksetup -listallhardwareports`
  /// (`en0`).
  public static func wifiDevice(_ listing: String) -> String? {
    let lines = listing.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let i = lines.firstIndex(of: "Hardware Port: Wi-Fi"),
      lines.indices.contains(i + 1),
      lines[i + 1].hasPrefix("Device: ")
    else { return nil }
    return String(lines[i + 1].dropFirst(8))
  }

  /// Whether `networksetup -getairportpower` says Wi-Fi is on; nil
  /// when it says neither.
  public static func wifiPower(_ output: String) -> Bool? {
    output.hasSuffix(": On") || output.contains(": On\n")
      ? true
      : output.hasSuffix(": Off") || output.contains(": Off\n")
        ? false : nil
  }

  /// `networkQuality -c`'s JSON as one line: `↓ 412 Mbps ↑ 38 Mbps 22
  /// ms`. Throughput comes in bits per second, the idle latency
  /// (`base_rtt`) in milliseconds.
  public static func speedtest(_ json: String) -> String? {
    guard
      let d = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        as? [String: Any],
      let down = (d["dl_throughput"] as? NSNumber)?.doubleValue,
      let up = (d["ul_throughput"] as? NSNumber)?.doubleValue
    else { return nil }
    let rtt =
      (d["base_rtt"] as? NSNumber).map {
        "  \(Int($0.doubleValue.rounded())) ms"
      } ?? ""
    return
      "↓ \(Int((down / 1e6).rounded())) Mbps  ↑ \(Int((up / 1e6).rounded())) Mbps\(rtt)"
  }

  /// A `run:` verb's shell line (`run:brew %s`) with `text` for `%s`,
  /// as typed: it is a command the person wrote, so it is not quoted.
  public static func run(_ value: String, _ text: String) -> String? {
    guard value.hasPrefix("run:"), value.contains("%s"), !text.isEmpty
    else { return nil }
    return String(value.dropFirst(4)).replacingOccurrences(
      of: "%s", with: text)
  }

  /// A link verb's template (`https://chatgpt.com/?q=%s`) with
  /// `text`, encoded, for `%s`.
  public static func link(_ template: String, _ text: String) -> URL?
  {
    let safe = CharacterSet(
      charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    guard template.contains("%s"), !text.isEmpty,
      let q = text.addingPercentEncoding(withAllowedCharacters: safe)
    else { return nil }
    return URL(
      string: template.replacingOccurrences(of: "%s", with: q))
  }
}
