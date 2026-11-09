#if FREO_SIRI_STRING_PROBE
import AppIntents

/// Diagnostic alternative to custom-entity resolution. Not in normal builds.
struct FreoStringRoomOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        try await FreoStore.shared.siriRoomSuggestions().map(\.name)
    }
}

struct FreoStringRoomProbeIntent: AppIntent {
    static let title: LocalizedStringResource = "Vacuum and mop by room name"
    static let openAppWhenRun = true
    @Parameter(title: "Room name", optionsProvider: FreoStringRoomOptions())
    var room: String
    static var parameterSummary: some ParameterSummary {
        Summary("Vacuum and mop \(\.$room)")
    }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        FreoSiriTrace.record("text room received", detail: room)
        let catalog = try await FreoStore.shared.siriRoomSuggestions()
        let matches = SiriRoomReference.matching(query: room, in: catalog)
        guard matches.count == 1 else {
            throw $room.needsValueError("Choose one saved robot room.")
        }
        FreoSiriTrace.record("mode command perform", detail: "vacuumMop / " + matches[0].name)
        let reply = try await FreoStore.shared.siriStart(mode: .vacuumMop, references: matches)
        return .result(dialog: "\(reply)")
    }
}
#endif
