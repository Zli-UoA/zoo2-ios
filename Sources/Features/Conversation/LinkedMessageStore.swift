import Foundation
import Observation

/// 取得するリンク先の 1 件。
struct LinkedMessageKey: Hashable, Sendable {
    let channelID: String
    let messageID: String
}

/// 本文のリンクが指すメッセージ。チャンネルごとに 1 本の取得を、画面にある行で共有する。
/// 同じメッセージは 1 回だけ取り、使う行がなくなって `releaseDelay` たったら止める。
@Observable @MainActor
final class LinkedMessageStore {
    /// 1 つのチャンネルの `ids` を取得し続ける（`ChatClient.observeLinkedMessages`）。
    typealias Observe = @MainActor (_ channelID: String, _ ids: [String],
                                    _ receive: @MainActor ([String: LinkedMessageFetch]) -> Void) async throws -> Void

    private(set) var results: [LinkedMessageKey: LinkedMessageFetch] = [:]
    private(set) var stalled: Set<LinkedMessageKey> = []
    @ObservationIgnored private let observe: Observe
    @ObservationIgnored private let loadTimeout: Duration
    @ObservationIgnored private let releaseDelay: Duration
    /// チャンネルごとの、取得する ID と、使っている行の数。
    @ObservationIgnored private var users: [String: [String: Int]] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var releases: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var timers: [LinkedMessageKey: Task<Void, Never>] = [:]
    @ObservationIgnored var onExpiredSession: (() -> Void)?

    init(loadTimeout: Duration = .seconds(10), releaseDelay: Duration = .seconds(30), observe: @escaping Observe) {
        self.observe = observe
        self.loadTimeout = loadTimeout
        self.releaseDelay = releaseDelay
    }

    func fetch(_ key: LinkedMessageKey) -> LinkedMessageFetch {
        results[key] ?? .loading(stalled: stalled.contains(key))
    }

    /// このチャンネルで取得した行に、暗号文の行があるか。
    func hasCiphertext(channelID: String) -> Bool {
        results.contains { key, fetch in
            guard key.channelID == channelID, case .found(let message) = fetch else { return false }
            return message.hasCiphertext
        }
    }

    /// 行が画面にある間、取得を続ける。行の `.task` から呼び、キャンセルで手放す。
    func watch(_ keys: [LinkedMessageKey]) async {
        guard !keys.isEmpty else { return }
        acquire(keys)
        defer { release(keys) }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    func shutdown() {
        tasks.values.forEach { $0.cancel() }
        releases.values.forEach { $0.cancel() }
        timers.values.forEach { $0.cancel() }
        tasks = [:]; releases = [:]; timers = [:]; users = [:]
        results = [:]; stalled = []
    }

    private func acquire(_ keys: [LinkedMessageKey]) {
        for (channelID, group) in Dictionary(grouping: keys, by: \.channelID) {
            releases.removeValue(forKey: channelID)?.cancel()
            var added = false
            for key in group {
                if users[channelID]?[key.messageID] == nil { added = true }
                users[channelID, default: [:]][key.messageID, default: 0] += 1
                startTimer(key)
            }
            if added || tasks[channelID] == nil { restart(channelID) }
        }
    }

    private func release(_ keys: [LinkedMessageKey]) {
        for key in keys {
            if let count = users[key.channelID]?[key.messageID] { users[key.channelID]?[key.messageID] = max(0, count - 1) }
        }
        for channelID in Set(keys.map(\.channelID)) {
            guard let ids = users[channelID], ids.values.allSatisfy({ $0 == 0 }), releases[channelID] == nil else { continue }
            releases[channelID] = Task { [weak self, delay = releaseDelay] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.stop(channelID)
            }
        }
    }

    private func stop(_ channelID: String) {
        releases[channelID] = nil
        tasks.removeValue(forKey: channelID)?.cancel()
        for messageID in (users.removeValue(forKey: channelID) ?? [:]).keys {
            let key = LinkedMessageKey(channelID: channelID, messageID: messageID)
            timers.removeValue(forKey: key)?.cancel()
            stalled.remove(key)
            // 失敗は覚えず、次に表示したときに取り直す。取得できた結果は残し、戻ったときに先に出す。
            if results[key] == .failed { results[key] = nil }
        }
    }

    private func startTimer(_ key: LinkedMessageKey) {
        guard results[key] == nil, timers[key] == nil, !stalled.contains(key) else { return }
        timers[key] = Task { [weak self, timeout = loadTimeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.timers[key] = nil
            self?.stalled.insert(key)
        }
    }

    private func restart(_ channelID: String) {
        tasks[channelID]?.cancel()
        let ids = (users[channelID] ?? [:]).keys.sorted()
        tasks[channelID] = Task { [weak self, observe = self.observe] in
            var delay = 1
            while !Task.isCancelled {
                do {
                    try await observe(channelID, ids) { found in
                        self?.apply(found, channelID: channelID)
                    }
                    return
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    if case ZooError.expiredSession = error {
                        self?.fail(ids, channelID: channelID)
                        self?.onExpiredSession?()
                        return
                    }
                    if case ZooError.rejected(let status, _) = error, (400..<500).contains(status), status != 429 {
                        self?.fail(ids, channelID: channelID)
                        return
                    }
                    // サーバーのエラーやオフラインは、間隔を空けてやり直す（10 秒を超えると画面は失敗を出す）。
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    private func apply(_ found: [String: LinkedMessageFetch], channelID: String) {
        guard !Task.isCancelled else { return }
        for (messageID, fetch) in found {
            let key = LinkedMessageKey(channelID: channelID, messageID: messageID)
            if results[key] != fetch { results[key] = fetch }
            timers.removeValue(forKey: key)?.cancel()
            if stalled.contains(key) { stalled.remove(key) }
        }
    }

    private func fail(_ ids: [String], channelID: String) {
        for messageID in ids {
            let key = LinkedMessageKey(channelID: channelID, messageID: messageID)
            // 取り直しに失敗したときは、前に取得できた結果を残す。
            if results[key] == nil { results[key] = .failed }
            timers.removeValue(forKey: key)?.cancel()
        }
    }
}
