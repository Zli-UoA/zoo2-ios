import SwiftUI

@MainActor
final class MessageRenderCache {
    private static let retainedNeighborCount = 10
    private(set) var states: [String: MessageRenderState] = [:]
    private var visibleIDs: Set<String> = []

    func state(for id: String) -> MessageRenderState {
        if let state = states[id] { return state }
        let state = MessageRenderState()
        states[id] = state
        return state
    }

    func retain(visibleIDs: [String], orderedIDs: [String]) {
        self.visibleIDs = Set(visibleIDs)
        updateMessages(orderedIDs)
    }

    func updateMessages(_ orderedIDs: [String]) {
        let indices = orderedIDs.indices.filter { visibleIDs.contains(orderedIDs[$0]) }
        guard let first = indices.first, let last = indices.last else {
            let available = Set(orderedIDs)
            evict(except: available)
            return
        }
        // スクロールで戻った際の再読み込みを防ぐため、行ビューの外で上下10件の表示状態を保持する。
        let lower = max(0, first - Self.retainedNeighborCount)
        let upper = min(orderedIDs.count, last + Self.retainedNeighborCount + 1)
        let retained = Set(orderedIDs[lower..<upper])
        evict(except: retained)
    }

    func cancelLoads() {
        for state in states.values { state.cancelLoads() }
    }

    private func evict(except retained: Set<String>) {
        for (id, state) in states where !retained.contains(id) { state.cancelLoads() }
        states = states.filter { retained.contains($0.key) }
    }
}

@Observable @MainActor
final class MessageRenderState {
    let id = UUID()
    @ObservationIgnored private var attachments: [String: AttachmentRenderState] = [:]

    func attachment(_ attachment: MessageAttachment) -> AttachmentRenderState {
        if let state = attachments[attachment.id], state.attachment == attachment { return state }
        attachments[attachment.id]?.cancelLoad()
        let state = AttachmentRenderState(attachment: attachment)
        attachments[attachment.id] = state
        return state
    }

    func retainAttachments(_ ids: Set<String>) {
        for (id, state) in attachments where !ids.contains(id) { state.cancelLoad() }
        attachments = attachments.filter { ids.contains($0.key) }
    }

    func cancelLoads() {
        for state in attachments.values { state.cancelLoad() }
    }
}

struct MessageContentView: View {
    let message: Message
    let workspace: WorkspaceStore
    @Bindable var renderState: MessageRenderState
    @ScaledMetric(relativeTo: .body) private var emojiHeight: CGFloat = 24
    @Environment(\.scenePhase) private var scenePhase

    private struct ImageLoadKey: Equatable {
        let stateID: UUID
        let urls: [URL]
        let active: Bool
    }

    var body: some View {
        let parts = MessageContent.parse(message.content.isEmpty ? "添付ファイルまたはアプリのメッセージ" : message.content, mention: workspace.mentionIdentity) {
            workspace.emojiImageURL(for: $0, message: message)
        }
        let urls = Array(Set(parts.compactMap { part -> URL? in
            if case .emoji(_, let url) = part { return url }
            return nil
        })).sorted { $0.absoluteString < $1.absoluteString }
        let states = Dictionary(uniqueKeysWithValues: urls.map { ($0, workspace.images.state(for: $0)) })
        let images = states.compactMapValues { $0.inlineImage(height: emojiHeight) }
        let server = workspace.client.serverURL
        let references = ChannelLink.references(in: message.content, server: server)
        // URL の文字そのものを書いたリンクだけを短くする。`[文字](URL)` の URL は書き換えない。
        let bare = parts.compactMap { part -> (URL, ChannelLink)? in
            guard case .link(let text, let url) = part, !message.content.contains("](\(text)"),
                  let link = ChannelLink(url, server: server) else { return nil }
            return (url, link)
        }
        let shortLinks = bare.reduce(into: [URL: MessageContentText.ShortLink]()) { result, entry in
            switch workspace.linkState(entry.1) {
            case .message(let channel, let preview):
                result[entry.0] = MessageContentText.ShortLink(
                    label: "\(preview.authorName)さん: \(workspace.linkLabel(for: channel))", isMessage: true)
            case .channel(let channel):
                result[entry.0] = MessageContentText.ShortLink(label: workspace.linkLabel(for: channel), isMessage: false)
            default: break
            }
        }
        let targets = bare.map(\.1) + references.map(\.link)
        // 行は画面の近くに来てから作られるので、取得もそのときに始まる。
        let linkedKeys = scenePhase == .active ? workspace.linkedKeys(for: targets) : []
        VStack(alignment: .leading, spacing: 6) {
            MessageContentText.render(parts, images: images, emojiHeight: emojiHeight, shortLinks: shortLinks)
                .tint(AppDesign.externalLink)
            ForEach(references) { reference in
                ChannelLinkCard(state: workspace.linkState(reference.link), workspace: workspace) { parentID in
                    Task { await workspace.openLink(reference.link, parentID: parentID) }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let link = ChannelLink(url, server: server) else { return .systemAction }
            var parentID: String?
            if case .message(_, let preview) = workspace.linkState(link) { parentID = preview.parentID }
            Task { await workspace.openLink(link, parentID: parentID) }
            return .handled
        })
        .task(id: linkedKeys) { await workspace.links.watch(linkedKeys) }
        .task(id: unknownAuthors(in: targets)) {
            // 一覧にない投稿者（Bot など）の名前を取る。
            await workspace.resolveAuthors(in: linkedMessages(for: targets))
        }
        .task(id: ImageLoadKey(stateID: renderState.id, urls: urls, active: scenePhase == .active)) {
            guard scenePhase == .active, !urls.isEmpty else { return }
            await workspace.images.watch(states, policy: .stored)
        }
    }

    private func linkedMessages(for targets: [ChannelLink]) -> [Message] {
        targets.compactMap { link in
            guard let messageID = link.linkedMessageID else { return nil }
            let key = LinkedMessageKey(channelID: link.channelID, messageID: messageID)
            if case .found(let message) = workspace.links.fetch(key) { return message }
            return nil
        }
    }

    private func unknownAuthors(in targets: [ChannelLink]) -> [String] {
        Set(linkedMessages(for: targets).map(\.user_id)).subtracting(workspace.people.keys).sorted()
    }

}

@MainActor
enum MessageContentText {
    /// このアプリのリンクの短い表示。
    struct ShortLink: Equatable {
        let label: String
        let isMessage: Bool
    }

    static func render(_ parts: [MessageContent.Part], images: [URL: UIImage], emojiHeight: CGFloat,
                       shortLinks: [URL: ShortLink] = [:]) -> Text {
        var runs: [Text] = []
        var text = AttributedString()
        func flush() {
            if !text.characters.isEmpty { runs.append(Text(text)); text = AttributedString() }
        }
        for part in parts {
            switch part {
            case .text(let value): text.append(AttributedString(value))
            case .link(let value, let url):
                let short = shortLinks[url]
                if short?.isMessage == true {
                    flush()
                    runs.append(Text("\(Image(systemName: "bubble.left")) ").foregroundStyle(AppDesign.externalLink))
                }
                var link = AttributedString(short?.label ?? value)
                link.link = url
                text.append(link)
            case .mention(let value, let isSelf):
                var mention = AttributedString(value)
                mention.foregroundColor = isSelf ? AppDesign.selectionForeground : AppDesign.link
                mention.backgroundColor = isSelf ? AppDesign.selectionBackground : AppDesign.accentBackground
                mention.font = .body.bold()
                text.append(mention)
            case .emoji(let name, let url):
                if let image = images[url] {
                    flush()
                    runs.append(Text(Image(uiImage: image)).baselineOffset(-emojiHeight / 6)
                        .accessibilityLabel(Text(verbatim: name)))
                } else { text.append(AttributedString(name)) }
            }
        }
        flush()
        return joined(runs[...])
    }

    private static func joined(_ runs: ArraySlice<Text>) -> Text {
        guard runs.count > 1 else { return runs.first ?? Text(verbatim: "") }
        // 入れ子を二分し、上限近い本文でも Text の再帰深度を対数に抑える。
        let middle = runs.index(runs.startIndex, offsetBy: runs.count / 2)
        return Text("\(joined(runs[..<middle]))\(joined(runs[middle...]))")
    }
}
