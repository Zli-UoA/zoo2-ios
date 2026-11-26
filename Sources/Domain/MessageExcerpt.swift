import Foundation

/// メッセージ本文を、リンクの埋め込みカードに出す短い素の文字列にする（Web の `messageExcerpt`）。
/// 装飾・リンク・コードの記法を外し、改行や連続する空白を 1 つにまとめ、長いときは切って「…」を付ける。
enum MessageExcerpt {
    static let maximumLength = 200

    private static let code = try! NSRegularExpression(pattern: #"(?s)```(?:[^\n`]*\n)?(.*?)```|`([^`\n]*)`"#)
    private static let function = try! NSRegularExpression(pattern: #"\$\[[A-Za-z0-9_.=,+\-]+[ \t\n]([^\[\]]*)\]"#)
    // 記法を外す順に並べる。リンクは文字を残し、装飾は中身を残す。
    private static let rules: [(NSRegularExpression, String)] = [
        (#"\??\[([^\[\]]*)\]\(https?://[^\s]*\)"#, "$1"),
        (#"</?(?:plain|center|small|b|i|s)>"#, " "),
        (#"(?m)^[ ]{0,3}#{1,6}[ \t]+"#, ""),
        (#"(?m)^>[ \t]?"#, ""),
        (#"\*\*\*([^*]+)\*\*\*"#, "$1"),
        (#"\*\*([^*]+)\*\*"#, "$1"),
        (#"__([^_]+)__"#, "$1"),
        (#"~~([^~]+)~~"#, "$1"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func make(_ content: String, maximumLength: Int = maximumLength) -> String {
        // コードの中身は記法を外さずに残すので、先に取り分ける。
        var codes: [String] = []
        var text = ""
        var cursor = content.startIndex
        for match in code.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
            guard let range = Range(match.range, in: content),
                  let body = Range(match.range(at: 1), in: content) ?? Range(match.range(at: 2), in: content) else { continue }
            text += content[cursor..<range.lowerBound]
            text += " \u{E000}\(codes.count)\u{E001} "
            codes.append(String(content[body]))
            cursor = range.upperBound
        }
        text += content[cursor...]
        // `$[fn 本文]` は内側から外す。入れ子は 16 段まで。
        for _ in 0..<16 {
            let next = replace(function, in: text, with: "$1")
            if next == text { break }
            text = next
        }
        for (rule, template) in rules { text = replace(rule, in: text, with: template) }
        for (index, value) in codes.enumerated() {
            text = text.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: value)
        }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maximumLength else { return collapsed }
        return collapsed.prefix(maximumLength).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
