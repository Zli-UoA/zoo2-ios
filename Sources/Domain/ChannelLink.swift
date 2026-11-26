import Foundation

/// このアプリのチャンネル・メッセージへのリンク。仕様は zoo2 の docs/mfm.md
/// 「チャンネル・メッセージのリンクの表示」にそろえる。
struct ChannelLink: Hashable, Sendable {
    let channelID: String
    var messageID: String? = nil
    var threadID: String? = nil

    /// リンクが指すメッセージ。`?message=` を優先し、`?thread=` だけのリンクはスレッドの親を指す。
    var linkedMessageID: String? { messageID ?? threadID }
}

/// 本文に書いたアプリ内リンクと、その URL。
struct ChannelLinkReference: Hashable, Identifiable, Sendable {
    let url: String
    let link: ChannelLink
    var id: String { url }
}

extension ChannelLink {
    /// 接続先（`server`）と同じ origin の `/channels/<ID>` だけを受け付ける。別の origin・別のパス・
    /// ユーザー情報の付いた URL は `nil`（外部のリンクとして扱う）。
    init?(_ url: URL, server: String) {
        guard let link = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let app = URLComponents(string: server),
              let scheme = link.scheme?.lowercased(), ["https", "http"].contains(scheme),
              scheme == app.scheme?.lowercased(),
              let host = link.host?.lowercased(), host == app.host?.lowercased(),
              Self.port(link) == Self.port(app),
              link.user == nil, link.password == nil else { return nil }
        let parts = link.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 || (parts.count == 4 && parts[3].isEmpty), parts[0].isEmpty, parts[1] == "channels",
              let channelID = String(parts[2]).removingPercentEncoding, !channelID.isEmpty else { return nil }
        func value(_ name: String) -> String? {
            link.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(channelID: channelID, messageID: value("message"), threadID: value("thread"))
    }

    private static func port(_ components: URLComponents) -> Int {
        components.port ?? (components.scheme?.lowercased() == "http" ? 80 : 443)
    }

    // コード・`<plain>`・サイレントリンク `?[文字](URL)` の中の URL からは、カードを作らない。
    private static let hidden = try! NSRegularExpression(
        pattern: #"(?s)```.*?```|`[^`\n]*`|<plain>.*?</plain>|\?\[[^\]\n]*\]\([^\s)]+\)"#)
    /// `[文字](URL)` は行き先だけを URL とする（文字に書いた URL は行き先ではない）。
    private static let markdown = try! NSRegularExpression(
        pattern: #"\[[^\]\n]*\]\((https?://(?:[^\s()]++|\([^\s()]*+\))++)\)"#)
    private static let urlCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._,/:%#@$&?!~=+-".unicodeScalars)

    /// `text` の先頭の `http://` か `https://` の URL。Web（`mfm-js`）と同じく、URL に使う ASCII の文字と、
    /// 対応のとれた括弧までを URL とし、末尾の句読点は除く。日本語や全角の記号が続いても、そこで終わる。
    static func leadingURL(_ text: Substring) -> Substring? {
        guard let scheme = ["https://", "http://"].first(where: { text.hasPrefix($0) }) else { return nil }
        let scalars = text.unicodeScalars
        var index = scalars.index(scalars.startIndex, offsetBy: scheme.count)
        // 閉じていない括弧の位置と、対応する閉じ括弧。
        var open: [(String.Index, Unicode.Scalar)] = []
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let used: Bool
            switch scalar {
            case "(", "[":
                open.append((index, scalar == "(" ? ")" : "]"))
                used = true
            case ")", "]": used = open.popLast()?.1 == scalar
            default: used = urlCharacters.contains(scalar)
            }
            if !used { break }
            index = scalars.index(after: index)
        }
        // 閉じていない括弧は、URL に含めない。
        var url = text[text.startIndex..<(open.first?.0 ?? index)]
        while let last = url.last, ".,!?:".contains(last) { url.removeLast() }
        return url.count > scheme.count ? url : nil
    }

    /// 1 つの本文から取得するリンク先のメッセージの数。他の人が書いた 1 件の投稿で、購読や要求が
    /// 増え続けないようにする。
    static let fetchLimit = 3

    /// 本文のリンクのうち、取得するもの。`embedded`（埋め込み）を先に、続けて `bare`（URL の文字そのもの）を、
    /// メッセージごとに数えて `fetchLimit` 件まで。チャンネルだけのリンクは取得しないので数えない。
    static func fetched(embedded: [ChannelLink], bare: [ChannelLink]) -> [ChannelLink] {
        var seen: Set<[String]> = []
        return (embedded + bare).filter { link in
            guard let messageID = link.linkedMessageID, seen.count < fetchLimit else { return false }
            return seen.insert([link.channelID, messageID]).inserted
        }
    }

    /// 投稿の下に埋め込むアプリ内リンク。Web と同じく、本文の URL を重複を除いて先頭から 3 件まで数える。
    static func references(in content: String, server: String) -> [ChannelLinkReference] {
        var visible = hidden.stringByReplacingMatches(
            in: content, range: NSRange(content.startIndex..., in: content), withTemplate: " ")
        visible = markdown.stringByReplacingMatches(
            in: visible, range: NSRange(visible.startIndex..., in: visible), withTemplate: " $1 ")
        var seen: Set<String> = []
        var result: [ChannelLinkReference] = []
        var start = visible.startIndex
        while let found = visible.range(of: "http", range: start..<visible.endIndex) {
            guard let value = leadingURL(visible[found.lowerBound...]) else {
                start = found.upperBound
                continue
            }
            // URL の中に書いた URL は数えない。
            start = value.endIndex
            guard let url = URL(string: String(value)), url.host?.isEmpty == false, url.user == nil,
                  url.password == nil, seen.insert(url.absoluteString).inserted else { continue }
            if let link = ChannelLink(url, server: server) {
                result.append(ChannelLinkReference(url: url.absoluteString, link: link))
            }
            if seen.count == 3 { break }
        }
        return result
    }
}

/// リンク先のメッセージの取得の状態。
enum LinkedMessageFetch: Equatable, Sendable {
    /// 取得中。`stalled` は、始めてから時間がたっても終わらない。
    case loading(stalled: Bool)
    case found(Message)
    /// 取得できたが、その ID のメッセージがない。
    case missing
    /// 再試行しても取得できない失敗（認証の期限切れ、権限の不足など）。
    case failed
}

/// 埋め込みカードと短いリンクに使う、リンク先のメッセージ。
struct LinkedMessagePreview: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case text(String)
        /// 暗号化されたメッセージ。本文は出さない。
        case encrypted
        /// 連携カード・部品・App のブロックの投稿。`content` は出さない。
        case app
        /// コメントのない転送。
        case forwarded
        case attachments(Int)
        case empty
    }

    let authorID: String
    let authorName: String
    let createdAt: String
    /// 返信なら、そのスレッドの親。
    let parentID: String?
    let body: Body
}

/// アプリ内リンクの行き先が、いま分かっていること。
enum ChannelLinkState: Equatable, Sendable {
    case loading
    /// 見られない。存在しない・削除済み・非公開で未参加を区別しない。
    case unavailable(message: Bool)
    /// 取得できなかった。見られるかは分からない。
    case failed
    case channel(Channel)
    case message(Channel, LinkedMessagePreview)

    /// 暗号化チャンネルとして扱うか（zoo2 の docs/e2ee.md「暗号化の格下げを防ぐ」）。サーバーが
    /// `encrypted = false` を配っても、端末の記録・`edm:` の名前・読み込み済みの暗号文の行があれば暗号化とする。
    static func treatsAsEncrypted(_ channel: Channel, recorded: Bool, hasCiphertext: Bool) -> Bool {
        channel.encrypted == true || recorded || channel.channel_name.hasPrefix("edm:") || hasCiphertext
    }

    /// `channel` は見られるチャンネルの一覧の行。ないときは、一覧の読み込み（`directoryReady`）が終わるまで
    /// 読み込み中とする。`fetch` はチャンネルだけのリンクでは使わない。
    static func resolve(_ link: ChannelLink, channel: Channel?, directoryReady: Bool, fetch: LinkedMessageFetch,
                        recorded: Bool, hasCiphertext: Bool, authorName: (String) -> String?) -> ChannelLinkState {
        let messageID = link.linkedMessageID
        guard var channel, channel.deleted_at == nil else {
            return directoryReady ? .unavailable(message: messageID != nil) : .loading
        }
        if treatsAsEncrypted(channel, recorded: recorded, hasCiphertext: hasCiphertext) { channel.encrypted = true }
        guard let messageID else { return .channel(channel) }
        let message: Message
        switch fetch {
        case .loading(let stalled): return stalled ? .failed : .loading
        case .failed: return .failed
        case .missing: return .unavailable(message: true)
        case .found(let value): message = value
        }
        guard message.id == messageID, message.channel_id == channel.id, message.deleted_at == nil else {
            return .unavailable(message: true)
        }
        let body: LinkedMessagePreview.Body
        if channel.encrypted == true || message.hasCiphertext {
            body = .encrypted
        } else if message.replacesContent {
            body = .app
        } else {
            let excerpt = MessageExcerpt.make(message.content)
            let attachments = message.display_data?.attachments.count ?? 0
            if !excerpt.isEmpty { body = .text(excerpt) }
            else if message.isForward { body = .forwarded }
            else if attachments > 0 { body = .attachments(attachments) }
            else { body = .empty }
        }
        return .message(channel, LinkedMessagePreview(
            authorID: message.user_id, authorName: authorName(message.user_id) ?? "ユーザー",
            createdAt: message.created_at, parentID: message.parent_id, body: body))
    }
}

extension Message {
    var hasCiphertext: Bool {
        switch ciphertext {
        case nil, .null?: false
        case .string(let value)?: !value.isEmpty
        default: true
        }
    }

    var isForward: Bool {
        if case .array(let ids)? = forwarded_message_ids?.parsed { return !ids.isEmpty }
        return false
    }

    /// 本文（`content`）の代わりに、部品・App のカード・連携カードを描く投稿か（Web の `messageBodySource`）。
    var replacesContent: Bool {
        if case .object(let document)? = components?.parsed, case .array(let parts)? = document["components"], !parts.isEmpty {
            // 部品の文書があるときは、本文を隠すフラグ（1 << 15）だけで決める。
            if case .number(let flags)? = document["flags"] { return Int(flags) & (1 << 15) != 0 }
            return false
        }
        if case .array(let blocks)? = app_blocks?.parsed, blocks.contains(where: {
            if case .object(let block) = $0 { return block["type"] == .string("card") }
            return false
        }) { return true }
        // 連携カードは、1 枚か `cards` の配列で、どのカードにも題名がある。
        guard case .object(let envelope)? = card.map({ JSONValue.string($0) })?.parsed else { return false }
        let cards: [JSONValue]
        if let list = envelope["cards"] {
            guard case .array(let values) = list else { return false }
            cards = values
        } else { cards = [.object(envelope)] }
        return !cards.isEmpty && cards.allSatisfy {
            if case .object(let card) = $0, case .string(let title)? = card["title"] {
                return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }
}

extension JSONValue {
    /// Electric の JSONB は文字列で届くことがあるので、文字列なら JSON として読む。
    var parsed: JSONValue? {
        guard case .string(let raw) = self else { return self }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }
}
