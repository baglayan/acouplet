import AppIntents

enum HeadphoneDestination: String, AppEnum {
    case settings
    case equalizer

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Headphone View"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .settings: "Headphone Settings",
        .equalizer: "Equalizer",
    ]
}

struct HeadphoneIntentNavigation: Sendable {
    let open: @MainActor @Sendable (HeadphoneDestination) -> Void
}

@available(macOS 27.0, *)
struct OpenHeadphoneViewIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Headphone View"
    static let supportedModes: IntentModes = .foreground
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "View") var target: HeadphoneDestination
    @Dependency var navigation: HeadphoneIntentNavigation

    init() {}

    init(target: HeadphoneDestination) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        navigation.open(target)
        return .result()
    }
}

struct HeadphoneControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@available(macOS 27.0, *)
struct HeadphoneNoiseControlAction: AppEntity {
    let id: String
    let title: String
    let modelName: String
    let symbolName: String?
    let systemSymbol: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Headphone Noise Control"
    static let defaultQuery = HeadphoneNoiseControlQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(modelName)",
            image: symbolName.map { .init(named: $0, isTemplate: true) } ?? .init(systemName: systemSymbol))
    }

    var controlTitle: String { "\(title) · \(modelName)" }
}

@available(macOS 27.0, *)
struct HeadphoneIntentControls: Sendable {
    let actions: @MainActor @Sendable () -> [HeadphoneNoiseControlAction]
    let resolve: @MainActor @Sendable ([String]) async throws -> [HeadphoneNoiseControlAction]
    let perform: @MainActor @Sendable (String) async throws -> Void
}

@available(macOS 27.0, *)
struct HeadphoneNoiseControlQuery: EntityQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Dependency var controls: HeadphoneIntentControls

    func entities(for identifiers: [String]) async throws -> [HeadphoneNoiseControlAction] {
        try await controls.resolve(identifiers)
    }

    func suggestedEntities() async throws -> [HeadphoneNoiseControlAction] {
        await controls.actions()
    }
}

@available(macOS 27.0, *)
struct HeadphoneNoiseControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Noise Control"

    @Parameter(title: "Headphone Action") var action: HeadphoneNoiseControlAction?
}

@available(macOS 27.0, *)
struct SetHeadphoneNoiseControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Headphone Noise Control"
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Headphone Action") var action: HeadphoneNoiseControlAction?
    @Dependency var controls: HeadphoneIntentControls

    init() {}

    init(action: HeadphoneNoiseControlAction?) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        guard let action else { throw HeadphoneControlError(message: String(localized: "Choose a headphone action in the control's settings first.")) }
        try await controls.perform(action.id)
        return .result()
    }
}

@available(macOS 27.0, *)
struct HeadphoneSpeakToChatAction: AppEntity {
    let id: String
    let enabled: Bool
    let modelName: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Speak-to-Chat Action"
    static let defaultQuery = HeadphoneSpeakToChatQuery()

    var title: String { enabled ? String(localized: "Turn On Speak-to-Chat") : String(localized: "Turn Off Speak-to-Chat") }
    var controlTitle: String { "\(title) · \(modelName)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(modelName)",
            image: .init(systemName: "person.wave.2"))
    }
}

@available(macOS 27.0, *)
struct HeadphoneIntentSpeakToChat: Sendable {
    let actions: @MainActor @Sendable () -> [HeadphoneSpeakToChatAction]
    let resolve: @MainActor @Sendable ([String]) async throws -> [HeadphoneSpeakToChatAction]
    let perform: @MainActor @Sendable (String) async throws -> Void
}

@available(macOS 27.0, *)
struct HeadphoneSpeakToChatQuery: EntityQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Dependency var controls: HeadphoneIntentSpeakToChat

    func entities(for identifiers: [String]) async throws -> [HeadphoneSpeakToChatAction] {
        try await controls.resolve(identifiers)
    }

    func suggestedEntities() async throws -> [HeadphoneSpeakToChatAction] {
        await controls.actions()
    }
}

@available(macOS 27.0, *)
struct HeadphoneSpeakToChatConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Speak-to-Chat"

    @Parameter(title: "Headphone Action") var action: HeadphoneSpeakToChatAction?
}

@available(macOS 27.0, *)
struct SetHeadphoneSpeakToChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Speak-to-Chat"
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Headphone Action") var action: HeadphoneSpeakToChatAction?
    @Dependency var controls: HeadphoneIntentSpeakToChat

    init() {}

    init(action: HeadphoneSpeakToChatAction?) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        guard let action else { throw HeadphoneControlError(message: String(localized: "Choose a headphone action in the control's settings first.")) }
        try await controls.perform(action.id)
        return .result()
    }
}
