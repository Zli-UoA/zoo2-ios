import AppIntents

@available(iOS 27.0, *)
struct ZooAssistantIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Zooアシスタント"
    static let description = IntentDescription("Zooの通話依頼を受け取り、相手を確認して音声通話を始めます。「○○につないで」「○○と声で話したい」のように依頼できます。")
    static var supportedModes: IntentModes { .foreground(.dynamic) }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "依頼", requestValueDialog: "Zooで誰と通話しますか？")
    var request: String
    @Parameter(title: "通話相手")
    var recipient: ZooRecipientEntity?

    static var parameterSummary: some ParameterSummary { Summary("Zooで\(\.$request)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let workspace = try await AppSession.shared.prepareForShortcut()
        let person = try await ZooAssistant(actions: ShortcutActions(workspace: workspace)).call(
            request: request,
            interpret: { try await ZooAssistantPCC.interpret(request: $0, recipients: $1) },
            choose: { candidates in
                let selected = try await $recipient.requestDisambiguation(
                    among: candidates.map(ZooRecipientEntity.init), dialog: "どちらのZooメンバーに電話しますか？")
                return selected.recipient
            },
            confirm: { person in
                try await requestConfirmation(dialog: "Zooで\(person.name)（@\(person.user_name)）さんに音声通話を発信しますか？")
            },
            prepareCall: {
                if systemContext.currentMode != .foreground {
                    guard systemContext.currentMode.canContinueInForeground else {
                        throw ZooError.auth("通話を始めるには、iPhoneのZooを開いてください。")
                    }
                    try await continueInForeground(alwaysConfirm: false)
                }
            }
        )
        return .result(dialog: "\(person.name)さんとの通話を開始しました。")
    }
}
