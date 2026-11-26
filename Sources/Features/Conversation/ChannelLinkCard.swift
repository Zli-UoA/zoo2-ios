import SwiftUI

/// このアプリのチャンネル・メッセージへのリンクの埋め込みカード。カードのどこを押しても移動する。
/// 見られない行き先は理由を区別せず「表示できません」とだけ出し、移動もしない。
struct ChannelLinkCard: View {
    let state: ChannelLinkState
    let workspace: WorkspaceStore
    /// 分かっていれば、リンク先の返信の親を渡して開く。
    let open: (String?) -> Void

    var body: some View {
        switch state {
        case .loading:
            RoundedRectangle(cornerRadius: 12).fill(AppDesign.surface)
                .frame(height: 84)
                .accessibilityElement()
                .accessibilityLabel("リンク先を読み込み中")
        case .failed:
            notice("リンク先を読み込めませんでした", systemImage: "icloud.slash")
        case .unavailable(let message):
            notice(message ? "メッセージを表示できません" : "チャンネルを表示できません", systemImage: "eye.slash")
        case .channel(let channel):
            button(parentID: nil) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.linkLabel(for: channel)).font(.subheadline.bold()).lineLimit(1)
                    if channel.encrypted == true {
                        note("暗号化チャンネル", systemImage: "lock")
                    } else if channel.is_private && !channel.is_dm {
                        note("非公開チャンネル", systemImage: "lock")
                    }
                    if let description = channel.description, !description.isEmpty {
                        Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .message(let channel, let preview):
            let label = workspace.linkLabel(for: channel)
            button(parentID: preview.parentID) {
                HStack(alignment: .top, spacing: 8) {
                    AvatarView(name: preview.authorName, url: workspace.people[preview.authorID]?.avatarURL,
                               dimension: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(preview.authorName).font(.subheadline.bold()).lineLimit(1)
                            if let time = LinkedMessageTime.text(preview.createdAt) {
                                Text(time).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text(preview.parentID == nil ? label : "\(label) 内のスレッド")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        messageBody(preview.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private func messageBody(_ body: LinkedMessagePreview.Body) -> some View {
        switch body {
        case .text(let excerpt): Text(excerpt).font(.subheadline).lineLimit(3)
        case .encrypted: note("このメッセージは暗号化されています", systemImage: "lock").italic()
        case .app: note("Appのメッセージ", systemImage: "square.grid.2x2")
        case .forwarded: note("メッセージを転送しました", systemImage: "arrowshape.turn.up.right")
        case .attachments(let count): note("添付ファイル \(count) 件", systemImage: "paperclip")
        case .empty: EmptyView()
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.subheadline).foregroundStyle(.secondary)
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        note(text, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppDesign.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func button<Content: View>(parentID: String?, @ViewBuilder content: () -> Content) -> some View {
        let label = content()
        return Button { open(parentID) } label: {
            label
                .padding(12)
                .frame(minHeight: AppDesign.minimumControlSize)
                .background(AppDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("リンク先を開きます")
    }
}

enum LinkedMessageTime {
    /// 埋め込みに添える日時。「11月23日 16:30」の形で、今年でなければ年も付ける。
    static func text(_ value: String, now: Date = Date()) -> String? {
        guard let date = ZooDate.parse(value) else { return nil }
        var style = Date.FormatStyle().month().day().hour().minute()
        if !Calendar.current.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style.locale(Locale(identifier: "ja_JP")))
    }
}
