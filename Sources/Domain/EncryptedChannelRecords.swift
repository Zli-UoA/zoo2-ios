import Foundation

/// 一度 `encrypted = true` と見たチャンネルの ID の、端末の記録。サーバーがあとで `encrypted = false` を
/// 配っても、リンクの埋め込みに本文を出さない。ID はサーバーも知っている値なので暗号化しない。
struct EncryptedChannelRecords {
    private let defaults: UserDefaults
    private let key: String

    init(server: String, userID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "zoo.e2ee.encryptedChannels:\(server)|\(userID.lowercased())"
    }

    func contains(_ channelID: String) -> Bool {
        defaults.stringArray(forKey: key)?.contains(channelID) == true
    }

    func remember(_ channelIDs: [String]) {
        guard !channelIDs.isEmpty else { return }
        let known = Set(defaults.stringArray(forKey: key) ?? [])
        let next = known.union(channelIDs)
        if next != known { defaults.set(next.sorted(), forKey: key) }
    }
}
