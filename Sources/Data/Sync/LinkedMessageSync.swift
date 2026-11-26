import Foundation

/// リンク先のメッセージだけを `messages` Shape（`log=changes_only`）の subset snapshot で取り、
/// 編集・削除を受け取り続ける（Web の on-demand の `messages` と同じ経路・権限）。端末には保存しない。
@MainActor
struct LinkedMessageSync {
    let api: APIClient
    let channelID: String

    /// `receive` には、取得が終わった ID ごとの結果を渡す。キャンセルされるか、失敗するまで戻らない。
    /// 1 件の取得がサーバーのエラーなどで失敗しても、ほかの取得と変化の受け取りは続け、間隔を空けて取り直す。
    func observe(_ ids: [String], receive: @MainActor ([String: LinkedMessageFetch]) -> Void) async throws {
        let valid = ids.filter { UUID(uuidString: $0) != nil }
        var state = MessageSyncState()
        var needsRows = true
        // まだ取得できていない ID と、次に取り直す時刻。
        var pending: [String] = []
        var retryAt = ContinuousClock.now
        var retryDelay = 1
        var sseFailures = 0
        while !Task.isCancelled {
            if state.shape.handle == nil || state.shape.offset == "now" {
                let request = try await api.request("api/shapes/messages", query: query(state))
                let (data, response) = try await api.transport.send(request)
                try Task.checkCancellation()
                state = try await applyLinkedState(state, data: data, response: response)
                needsRows = true
                if state.shape.handle == nil || state.shape.offset == "now" {
                    try await Task.sleep(for: .milliseconds(500))
                }
                continue
            }
            if needsRows || (!pending.isEmpty && ContinuousClock.now >= retryAt) {
                if needsRows {
                    pending = valid
                    retryDelay = 1
                    needsRows = false
                }
                var failed: [String] = []
                do {
                    for id in pending {
                        do {
                            try await load(id, state: &state)
                        } catch where isTransient(error) {
                            failed.append(id)
                        }
                    }
                } catch MessageSyncError.reset {
                    state = MessageSyncState()
                    needsRows = true
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                pending = failed
                retryAt = ContinuousClock.now + .seconds(retryDelay)
                retryDelay = min(retryDelay * 2, 30)
                receive(try results(ids.filter { !pending.contains($0) }, state: state))
            }
            let useSSE = state.shape.isLive && sseFailures < 3
            let started = ContinuousClock.now
            do {
                try await ElectricTransport(api: api).read("api/shapes/messages", query: query(state), sse: useSSE) { data, response in
                    state = try await applyLinkedState(state, data: data, response: response)
                    // 取り直し（409・must-refetch）のあとは、上で行を取り直してから渡す。
                    if state.shape.handle != nil, state.shape.offset != "now" {
                        receive(try results(ids.filter { !pending.contains($0) }, state: state))
                    }
                }
            } catch where useSSE && isSSETransportFailure(error) && !Task.isCancelled {
                sseFailures += 1
                try await Task.sleep(for: .seconds(1))
                continue
            }
            if useSSE { sseFailures = started.duration(to: .now) < .seconds(1) ? sseFailures + 1 : 0 }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CancellationError()
    }

    /// 間隔を空けてやり直せば取れる可能性がある失敗（サーバーのエラー、混雑、通信の失敗）。
    private func isTransient(_ error: Error) -> Bool {
        if case ZooError.rejected(let status, _) = error { return status >= 500 || status == 429 }
        return error is URLError
    }

    private func query(_ state: MessageSyncState) -> [String: String] {
        state.query.merging(["channel_id": channelID]) { _, new in new }
    }

    private func load(_ id: String, state: inout MessageSyncState) async throws {
        var parameters = query(state)
        parameters["live"] = nil
        parameters["cursor"] = nil
        parameters["subset__where"] = "id = $1"
        parameters["subset__params"] = String(decoding: try JSONEncoder().encode(["1": id]), as: UTF8.self)
        parameters["subset__order_by"] = "created_at DESC, id DESC"
        parameters["subset__limit"] = "1"
        let request = try await api.request("api/shapes/messages", query: parameters)
        let (data, response) = try await api.transport.send(request)
        try Task.checkCancellation()
        if response.statusCode == 409 { throw MessageSyncError.reset }
        _ = try state.addSnapshot(data, response: response)
    }

    private func results(_ ids: [String], state: MessageSyncState) throws -> [String: LinkedMessageFetch] {
        var result: [String: LinkedMessageFetch] = [:]
        for id in ids {
            if let row = state.shape.rows.values.first(where: { $0["id"]?.text == id }) {
                result[id] = .found(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(row)))
            } else {
                result[id] = .missing
            }
        }
        return result
    }
}

@concurrent private func applyLinkedState(_ original: MessageSyncState, data: Data,
                                         response: HTTPURLResponse) async throws -> MessageSyncState {
    var state = original
    try state.apply(data, response: response)
    return state
}
