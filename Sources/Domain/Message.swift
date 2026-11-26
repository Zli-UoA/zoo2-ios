import Foundation

struct Message: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var user_id: String
    var channel_id: String
    var content: String
    var created_at: String
    var updated_at: String?
    var deleted_at: String?
    var parent_id: String?
    var card: String?
    var display_data: MessageDisplayData?
    // 以下はリンクの埋め込みの判定にだけ使う。REST と Electric で型が異なるので、そのまま受け取る。
    var components: JSONValue? = nil
    var app_blocks: JSONValue? = nil
    var forwarded_message_ids: JSONValue? = nil
    var ciphertext: JSONValue? = nil

    var date: Date? { ZooDate.parse(created_at) }
}
