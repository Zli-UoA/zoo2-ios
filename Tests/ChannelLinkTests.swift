import Foundation
import Testing
@testable import Zoo

@Suite("チャンネル・メッセージのリンク")
struct ChannelLinkTests {
    private let server = "https://zli.chat"
    private let channel = Channel(id: "general", channel_name: "general", description: "雑談",
                                  is_private: false, is_dm: false)
    private let link = ChannelLink(channelID: "general", messageID: "m1")

    private func message(content: String = "**こんにちは**", configure: (inout Message) -> Void = { _ in }) -> Message {
        var message = Message(id: "m1", user_id: "alice", channel_id: "general", content: content,
                              created_at: "2026-11-23 07:30:00")
        configure(&message)
        return message
    }

    private func resolve(_ fetch: LinkedMessageFetch, link: ChannelLink? = nil, channel: Channel? = nil,
                         listed: Bool = true, ready: Bool = true, recorded: Bool = false,
                         ciphertext: Bool = false) -> ChannelLinkState {
        ChannelLinkState.resolve(
            link ?? self.link, channel: listed ? channel ?? self.channel : nil, directoryReady: ready, fetch: fetch,
            recorded: recorded, hasCiphertext: ciphertext, authorName: { $0 == "alice" ? "アリス" : nil })
    }

    private func body(_ state: ChannelLinkState) -> LinkedMessagePreview.Body? {
        if case .message(_, let preview) = state { return preview.body }
        return nil
    }

    private func parse(_ value: String) -> ChannelLink? {
        URL(string: value).flatMap { ChannelLink($0, server: server) }
    }

    @Test("このアプリのチャンネルの画面だけをアプリ内リンクにする")
    func parsing() {
        #expect(parse("https://zli.chat/channels/c1") == ChannelLink(channelID: "c1"))
        #expect(parse("https://ZLI.chat:443/channels/c1/") == ChannelLink(channelID: "c1"))
        #expect(parse("https://zli.chat/channels/c1?thread=m1&message=m2&x=1")
                == ChannelLink(channelID: "c1", messageID: "m2", threadID: "m1"))
        #expect(parse("https://zli.chat/channels/a%20b")?.channelID == "a b")
        #expect(parse("https://zli.chat/channels/c1?message=")?.messageID == nil)
        for other in ["http://zli.chat/channels/c1", "https://zli.chat:8443/channels/c1",
                      "https://zli.chat.example/channels/c1", "https://user@zli.chat/channels/c1",
                      "https://example.com/channels/c1", "https://zli.chat/channels",
                      "https://zli.chat/channels/c1/settings", "https://zli.chat/api/channels/c1",
                      "https://zli.chat/", "ftp://zli.chat/channels/c1"] {
            #expect(parse(other) == nil, "\(other)")
        }
        #expect(ChannelLink(channelID: "c", threadID: "p").linkedMessageID == "p")
        #expect(ChannelLink(channelID: "c", messageID: "m", threadID: "p").linkedMessageID == "m")
    }

    @Test("URL は Web と同じ位置で終え、[文字](URL) は行き先だけを数える")
    func urlEnds() {
        let url = "\(server)/channels/a?message=m"
        for text in ["\(url)を見て", "詳しくは\(url)。", "「\(url)」", "（\(url)）", "(\(url)).", "<\(url)>",
                     "\(url)(未閉じ"] {
            #expect(ChannelLink.references(in: text, server: server).map(\.url) == [url], "\(text)")
        }
        #expect(ChannelLink.references(in: "[\(server)/channels/a](\(server)/channels/b)", server: server)
            .map(\.link.channelID) == ["b"])
        #expect(ChannelLink.leadingURL("https://a.example/wiki/A_(b) x") == "https://a.example/wiki/A_(b)")
        #expect(ChannelLink.leadingURL("https://あ") == nil)
    }

    @Test("1 つの本文から取得するのは 3 件のメッセージまで")
    func fetchLimit() {
        func link(_ n: Int) -> ChannelLink { ChannelLink(channelID: "c\(n)", messageID: "m\(n)") }
        let fetched = ChannelLink.fetched(embedded: [link(2), ChannelLink(channelID: "only")],
                                          bare: [link(1), link(2), link(3), link(4)])
        #expect(fetched == [link(2), link(1), link(3)])
    }

    @Test("コードとサイレントリンクを除き、本文の先頭 3 件の URL からアプリ内リンクを選ぶ")
    func references() {
        let content = "\(server)/channels/a `\(server)/channels/code` ?[静か](\(server)/channels/quiet)\n" +
            "https://example.com/x と \(server)/channels/b。 \(server)/channels/c"
        #expect(ChannelLink.references(in: content, server: server).map(\.link.channelID) == ["a", "b"])
        #expect(ChannelLink.references(in: "\(server)/channels/a \(server)/channels/a", server: server).count == 1)
        #expect(ChannelLink.references(in: "<plain>\(server)/channels/a</plain>", server: server).isEmpty)
    }

    @Test("一覧にないチャンネルは、一覧の読み込み後に見られないと扱う")
    func directory() {
        #expect(resolve(.loading(stalled: false), listed: false, ready: false) == .loading)
        #expect(resolve(.loading(stalled: false), listed: false) == .unavailable(message: true))
        #expect(resolve(.loading(stalled: false), link: ChannelLink(channelID: "general"), listed: false)
                == .unavailable(message: false))
    }

    @Test("取得の状態を、見られない場合と区別する")
    func fetching() {
        #expect(resolve(.loading(stalled: false)) == .loading)
        #expect(resolve(.loading(stalled: true)) == .failed)
        #expect(resolve(.failed) == .failed)
        #expect(resolve(.missing) == .unavailable(message: true))
        #expect(resolve(.found(message { $0.deleted_at = "2026-11-24" })) == .unavailable(message: true))
        var elsewhere = message()
        elsewhere.channel_id = "other"
        #expect(resolve(.found(elsewhere)) == .unavailable(message: true))
        #expect(resolve(.loading(stalled: false), link: ChannelLink(channelID: "general")) == .channel(channel))
    }

    @Test("投稿者と素の要約を出す")
    func preview() {
        let state = resolve(.found(message { $0.parent_id = "p" }))
        #expect(state == .message(channel, LinkedMessagePreview(
            authorID: "alice", authorName: "アリス", createdAt: "2026-11-23 07:30:00", parentID: "p",
            body: .text("こんにちは"))))
    }

    @Test("暗号化チャンネルは本文を出さない")
    func encrypted() {
        var locked = channel
        locked.encrypted = true
        #expect(body(resolve(.found(message()), channel: locked)) == .encrypted)
        #expect(body(resolve(.found(message()), recorded: true)) == .encrypted)
        var direct = channel
        direct.channel_name = "edm:alice:bob"
        #expect(body(resolve(.found(message()), channel: direct)) == .encrypted)
        #expect(body(resolve(.found(message()), ciphertext: true)) == .encrypted)
        #expect(body(resolve(.found(message { $0.ciphertext = .string("{}") }))) == .encrypted)
        if case .channel(let shown) = resolve(.missing, link: ChannelLink(channelID: "general"), recorded: true) {
            #expect(shown.encrypted == true)
        } else { Issue.record("チャンネルの表示にならない") }
    }

    @Test("カードの投稿・転送・添付だけの投稿は content を出さない")
    func otherKinds() {
        #expect(body(resolve(.found(message { $0.card = #"{"title":"通知"}"# }))) == .app)
        #expect(body(resolve(.found(message { $0.card = #"{"cards":[{"title":"通知"}]}"# }))) == .app)
        #expect(body(resolve(.found(message { $0.card = "{}" }))) == .text("こんにちは"))
        #expect(body(resolve(.found(message { $0.app_blocks = .string(#"[{"type":"card"}]"#) }))) == .app)
        #expect(body(resolve(.found(message {
            $0.components = .string(#"{"flags":32768,"components":[{"type":10}]}"#)
        }))) == .app)
        #expect(body(resolve(.found(message {
            $0.components = .string(#"{"components":[{"type":10}]}"#)
            $0.card = #"{"title":"通知"}"#
        }))) == .text("こんにちは"))
        #expect(body(resolve(.found(message(content: "") {
            $0.forwarded_message_ids = .string(#"["x"]"#)
        }))) == .forwarded)
        #expect(body(resolve(.found(message(content: "") {
            $0.display_data = MessageDisplayData(attachments: [
                MessageAttachment(id: "a", file_name: "a.png", content_type: "image/png"),
            ])
        }))) == .attachments(1))
        #expect(body(resolve(.found(message(content: "")))) == .empty)
    }

    @Test("要約は装飾・リンク・コードの記法を外す")
    func excerpt() {
        let content = "# 見出し\n**太字** [リンク](https://example.com/x) https://example.com\n" +
            "```swift\nlet a = **b**\n```\n<plain>本文</plain>\n> 引用\n<center>中央</center> $[x2 $[tada 大きい]]"
        #expect(MessageExcerpt.make(content)
                == "見出し 太字 リンク https://example.com let a = **b** 本文 引用 中央 大きい")
        #expect(MessageExcerpt.make(" \n ").isEmpty)
        #expect(MessageExcerpt.make(String(repeating: "a", count: 300)) == String(repeating: "a", count: 200) + "…")
        #expect(MessageExcerpt.make("snake_case_name と 2*3*4") == "snake_case_name と 2*3*4")
    }

    @Test("暗号化チャンネルの記録は、アカウントごとに残る")
    func records() throws {
        let suite = "channel-link-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = EncryptedChannelRecords(server: server, userID: "Alice", defaults: defaults)
        records.remember(["c1"])
        records.remember([])
        #expect(EncryptedChannelRecords(server: server, userID: "alice", defaults: defaults).contains("c1"))
        #expect(!EncryptedChannelRecords(server: server, userID: "bob", defaults: defaults).contains("c1"))
    }
}
