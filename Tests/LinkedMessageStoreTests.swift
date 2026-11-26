import Foundation
import Testing
@testable import Zoo

@MainActor @Suite("リンク先のメッセージの取得")
struct LinkedMessageStoreTests {
    /// 取得の呼び出しを記録し、テストから結果や失敗を届ける。
    @MainActor
    private final class Source {
        private(set) var calls: [(channelID: String, ids: [String])] = []
        private(set) var stopped = 0
        var found: [String: LinkedMessageFetch] = [:]
        var failure: ZooError?

        var observe: LinkedMessageStore.Observe {
            // テストの後も止まる前の取得が参照するので、強く持つ。
            { channelID, ids, receive in
                self.calls.append((channelID, ids))
                defer { self.stopped += 1 }
                while true {
                    if let failure = self.failure { throw failure }
                    if !self.found.isEmpty { receive(self.found.filter { ids.contains($0.key) }) }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
    }

    private let key = LinkedMessageKey(channelID: "c1", messageID: "m1")
    private let message = Message(id: "m1", user_id: "alice", channel_id: "c1", content: "本文",
                                  created_at: "2026-11-23 07:30:00")

    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test("同じチャンネルのリンクは 1 本の取得を共有する")
    func shared() async {
        let source = Source()
        let store = LinkedMessageStore(observe: source.observe)
        let first = Task { await store.watch([key]) }
        await wait { source.calls.count == 1 }
        let second = Task { await store.watch([key]) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.calls.count == 1)
        source.found = ["m1": .found(message)]
        await wait { store.fetch(key) == .found(message) }
        first.cancel(); second.cancel()
        store.shutdown()
    }

    @Test("時間がたっても終わらなければ、読み込めなかったものとする")
    func stalls() async {
        let source = Source()
        let store = LinkedMessageStore(loadTimeout: .milliseconds(20), observe: source.observe)
        #expect(store.fetch(key) == .loading(stalled: false))
        let row = Task { await store.watch([key]) }
        await wait { store.fetch(key) == .loading(stalled: true) }
        source.found = ["m1": .missing]
        await wait { store.fetch(key) == .missing }
        row.cancel()
        store.shutdown()
    }

    @Test("権限の失敗は取り直さず、閉じたあとの表示で取り直す")
    func rejected() async {
        let source = Source()
        source.failure = .rejected(403, "")
        let store = LinkedMessageStore(releaseDelay: .milliseconds(20), observe: source.observe)
        let row = Task { await store.watch([key]) }
        await wait { store.fetch(key) == .failed }
        #expect(source.calls.count == 1)
        row.cancel()
        await wait { store.fetch(key) == .loading(stalled: false) }
        source.failure = nil
        source.found = ["m1": .found(message)]
        let again = Task { await store.watch([key]) }
        await wait { store.fetch(key) == .found(message) }
        again.cancel()
        store.shutdown()
    }

    @Test("使う行がなくなってしばらくすると取得を止め、結果は残す")
    func released() async {
        let source = Source()
        source.found = ["m1": .found(message)]
        let store = LinkedMessageStore(releaseDelay: .milliseconds(20), observe: source.observe)
        let row = Task { await store.watch([key]) }
        await wait { store.fetch(key) == .found(message) }
        row.cancel()
        await wait { source.stopped == 1 }
        #expect(store.fetch(key) == .found(message))
        store.shutdown()
    }
}
