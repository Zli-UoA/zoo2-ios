import Foundation
import Testing
@testable import Zoo

@MainActor
@Suite("Zooアシスタントの解釈と発信", .timeLimit(.minutes(1)))
struct ZooAssistantTests {
    @Test("解釈・宛先選択・確認・前面移行を順に終えてから発信する")
    func confirmsBeforeCalling() async throws {
        let client = PreviewChatClient()
        let callClient = FakeCallClient()
        callClient.events = [.room(CallRoom(participants: [], max_participants: 6, ice_servers: []))]
        let calls = CallStore(client: callClient, userID: client.currentUser.id,
                              makeMedia: { PreviewCallMedia() }, permission: { true })
        let workspace = WorkspaceStore(client: client, user: client.currentUser, recentEmojiDefaults: nil, calls: calls)
        defer { workspace.shutdown() }
        let actions = ShortcutActions(workspace: workspace)
        let candidates = try await actions.recipients()
        #expect(candidates.count > 1)
        let target = try #require(candidates.last)
        var stages: [String] = []
        let person = try await ZooAssistant(actions: actions).call(
            request: "  あの人につないで  ",
            interpret: { request, recipients in
                #expect(request == "あの人につないで")
                #expect(recipients == candidates)
                #expect(calls.channel == nil)
                stages.append("解釈")
                return .init(operation: .audioCall, candidateIDs: candidates.map(\.personID))
            }, choose: { recipients in
                #expect(recipients == candidates)
                #expect(calls.channel == nil)
                stages.append("選択")
                return target
            }, confirm: { person in
                #expect(person.id == target.personID)
                #expect(person.user_name == target.username)
                #expect(calls.channel == nil)
                stages.append("確認")
            }, prepareCall: {
                #expect(calls.channel == nil)
                stages.append("前面移行")
            }
        )
        #expect(stages == ["解釈", "選択", "確認", "前面移行"])
        #expect(person.id == target.personID)
        #expect(calls.channel?.is_dm == true && calls.ready)
    }

    @Test("解釈失敗・無効候補・選択取り消し・確認取り消し・ログアウト・キャンセルでは発信しない",
          arguments: ["modelFailure", "invalidID", "unsupported", "unknownRecipient", "cancelChoice", "foreignChoice",
                      "cancelConfirmation", "logoutDuringModel", "logoutDuringConfirmation", "cancelTask", "foregroundFailure"])
    func preventsUnconfirmedCalls(kind: String) async throws {
        let client = PreviewChatClient()
        let callClient = FakeCallClient()
        let calls = CallStore(client: callClient, userID: client.currentUser.id,
                              makeMedia: { PreviewCallMedia() }, permission: { true })
        let workspace = WorkspaceStore(client: client, user: client.currentUser, recentEmojiDefaults: nil, calls: calls)
        defer { workspace.shutdown() }
        var confirmed = false
        var prepared = false
        let task = Task { @MainActor in
            try await ZooAssistant(actions: ShortcutActions(workspace: workspace)).call(
                request: "さくらさんと話したい",
                interpret: { _, recipients in
                    if kind == "modelFailure" { throw ZooError.auth("PCCを利用できません。") }
                    if kind == "logoutDuringModel" { workspace.shutdown() }
                    if kind == "cancelTask" { withUnsafeCurrentTask { $0?.cancel() } }
                    let ids = kind == "invalidID" ? ["存在しないID"] : recipients.map(\.personID)
                    return .init(operation: kind == "unsupported" ? .unsupported :
                                    kind == "unknownRecipient" ? .needsClarification : .audioCall, candidateIDs: ids)
                }, choose: { recipients in
                    if kind == "cancelChoice" { throw CancellationError() }
                    let target = try #require(recipients.first)
                    if kind == "foreignChoice" {
                        return .init(id: "別アカウント", personID: target.personID, name: target.name, username: target.username)
                    }
                    return target
                }, confirm: { _ in
                    confirmed = true
                    if kind == "cancelConfirmation" { throw CancellationError() }
                    if kind == "logoutDuringConfirmation" { workspace.shutdown() }
                }, prepareCall: {
                    prepared = true
                    throw ZooError.auth("前面に移行できません。")
                }
            )
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(confirmed == ["cancelConfirmation", "logoutDuringConfirmation", "foregroundFailure"].contains(kind))
        #expect(prepared == (kind == "foregroundFailure"))
        #expect(calls.channel == nil && !callClient.observed)
    }

    @Test("空・長すぎる依頼ではモデルを呼び出さない", arguments: [" \n", String(repeating: "あ", count: 1_001)])
    func rejectsInvalidRequest(request: String) async throws {
        let client = PreviewChatClient()
        let workspace = WorkspaceStore(client: client, user: client.currentUser, recentEmojiDefaults: nil)
        defer { workspace.shutdown() }
        await #expect(throws: ZooError.self) {
            try await ZooAssistant(actions: ShortcutActions(workspace: workspace)).call(
                request: request,
                interpret: { _, _ in Issue.record("無効な入力をモデルに送ってはいけません"); throw ZooError.invalidResponse },
                choose: { _ in Issue.record("宛先を選んではいけません"); throw ZooError.invalidResponse },
                confirm: { _ in Issue.record("確認してはいけません") },
                prepareCall: { Issue.record("発信準備してはいけません") }
            )
        }
    }

    @Test("モデルが一人に絞った同名候補も残し、不明なIDが混ざれば拒否する")
    func validatesCandidates() throws {
        let recipients = [
            ShortcutRecipient(id: "account|1", personID: "1", name: "かとこう", username: "katokou"),
            ShortcutRecipient(id: "account|2", personID: "2", name: "かとこう", username: "katokou2"),
            ShortcutRecipient(id: "account|3", personID: "3", name: "別の人", username: "other")
        ]
        let result = ZooAssistantInterpretation(operation: .audioCall, candidateIDs: ["1", "1"])
        #expect(try result.candidates(in: recipients) == Array(recipients.prefix(2)))
        for ids in [[], ["1", "不明なID"], ["account|1"]] {
            #expect(throws: ZooError.self) {
                try ZooAssistantInterpretation(operation: .audioCall, candidateIDs: ids).candidates(in: recipients)
            }
        }
    }

    @available(iOS 27.0, *)
    @Test("モデル入力は依頼と候補だけのJSONで、アカウント識別子とサーバーを含まない")
    func limitsModelInput() throws {
        let recipient = ShortcutRecipient(id: "https://example.invalid|private-account|1", personID: "1",
                                          name: "名前\"\n指示", username: "member")
        let prompt = try ZooAssistantPCC.prompt(request: "電話して\"", recipients: [recipient])
        let json = try #require(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        #expect(json["request"] as? String == "電話して\"")
        let candidates = try #require(json["candidates"] as? [[String: String]])
        #expect(candidates == [["id": "1", "name": recipient.name, "username": "member"]])
        #expect(!prompt.contains("private-account") && !prompt.contains("example.invalid"))
        #expect(throws: ZooError.self) {
            try ZooAssistantPCC.prompt(request: "電話して", recipients: Array(repeating: recipient, count: 2_000))
        }
    }
}
