import AppIntents
import Foundation
#if os(iOS)
import CoreSpotlight
#endif

/// Siri sees cleaning modes, while the command codec remains the sole owner
/// of their wire encoding. No room names or device identifiers are predefined.
enum FreoIntentCleaningMode: String, AppEnum {
    case vacuum, mop, vacuumMop, vacuumThenMop

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Cleaning mode"
    static let caseDisplayRepresentations: [FreoIntentCleaningMode: DisplayRepresentation] = [
        .vacuum: DisplayRepresentation(title: "Vacuum", synonyms: ["Vacuum only"]),
        .mop: DisplayRepresentation(title: "Mop", synonyms: ["Mop only"]),
        .vacuumMop: DisplayRepresentation(title: "Vacuum and mop", synonyms: ["Vacuum and mop together"]),
        .vacuumThenMop: DisplayRepresentation(title: "Vacuum then mop", synonyms: ["Vacuum before mopping"])
    ]
    var cleaningMode: CleaningMode {
        switch self {
        case .vacuum: return .vacuum
        case .mop: return .mop
        case .vacuumMop: return .vacuumMop
        case .vacuumThenMop: return .vacuumThenMop
        }
    }
}

/// A stable, scoped identifier is persisted by Shortcuts, never authentication.
/// Every invocation resolves it against this robot's current saved rooms again.
struct FreoRoomEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Robot room"
    static let defaultQuery = FreoRoomQuery()

    let id: String
    @Property(title: "Room name") var name: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
    init(_ room: SiriRoomReference) { id = room.id; name = room.name }

    func checkedReference() throws -> SiriRoomReference {
        guard let room = SiriRoomReference(id: id, name: name) else {
            throw ConnectorError.invalid("This saved room is no longer recognized. Open Narwal and load its current rooms.")
        }
        return room
    }
}

#if os(iOS)
@available(iOS 18.0, *)
extension FreoRoomEntity: IndexedEntity {}
#endif

/// Keep the system's room index synchronized with the app's private catalog.
/// Serialize replacements so an older refresh cannot restore signed-out rooms.
@MainActor
enum FreoSiriRoomIndex {
    private static var pending: Task<Void, Never>?
    static func refresh(_ references: [SiriRoomReference]) {
        #if os(iOS)
        guard #available(iOS 18.0, *) else { return }
        let previous = pending
        pending = Task {
            await previous?.value
            do {
                let index = CSSearchableIndex(name: "FreoRooms")
                let defaults = UserDefaults.standard
                let key = "freo.indexedSiriRoomIDs"
                let saved = defaults.stringArray(forKey: key) ?? []
                let current = references.map(\.id)
                if references.isEmpty {
                    try await index.deleteAppEntities(ofType: FreoRoomEntity.self)
                } else {
                    let obsolete = Array(Set(saved.prefix(100)).subtracting(current))
                    if !obsolete.isEmpty {
                        try await index.deleteAppEntities(identifiedBy: obsolete, ofType: FreoRoomEntity.self)
                    }
                    try await index.indexAppEntities(references.map(FreoRoomEntity.init))
                }
                defaults.set(current, forKey: key)
                FreoSiriTrace.record("room index updated", detail: String(references.count) + " rooms")
            } catch {
                FreoSiriTrace.record("room index failed", detail: error.localizedDescription)
            }
        }
        #endif
    }
}

struct FreoRoomQuery: EntityStringQuery, EnumerableEntityQuery {
    func allEntities() async throws -> [FreoRoomEntity] {
        FreoSiriTrace.record("all rooms requested", detail: "Enumerating saved rooms")
        return try await suggestedEntities()
    }
    func entities(for identifiers: [String]) async throws -> [FreoRoomEntity] {
        FreoSiriTrace.record("room identifiers requested", detail: String(identifiers.count))
        try Task.checkCancellation()
        guard identifiers.count <= 100, Set(identifiers).count == identifiers.count else {
            throw ConnectorError.invalid("Choose each saved room once, up to 100 rooms.")
        }
        guard !identifiers.isEmpty else { return [] }
        let rooms = try await FreoStore.shared.siriRoomSuggestions()
        FreoSiriTrace.record("room query returned", detail: String(rooms.count) + " rooms")
        try Task.checkCancellation()
        var result: [FreoRoomEntity] = []
        for id in identifiers {
            guard let room = try await FreoStore.shared.resolveSiriRoom(identifier: id, current: rooms) else {
                throw ConnectorError.invalid("A saved room changed or is no longer available. Open Narwal, reload its rooms, and choose the rooms again in this shortcut.")
            }
            result.append(FreoRoomEntity(room))
        }
        return result
    }
    func suggestedEntities() async throws -> [FreoRoomEntity] {
        try Task.checkCancellation()
        let rooms = try await FreoStore.shared.siriRoomSuggestions()
        FreoSiriTrace.record("room query returned", detail: String(rooms.count) + " rooms")
        try Task.checkCancellation()
        return rooms.map(FreoRoomEntity.init)
    }
    func entities(matching string: String) async throws -> [FreoRoomEntity] {
        try Task.checkCancellation()
        let rooms = try await FreoStore.shared.siriRoomSuggestions()
        FreoSiriTrace.record("room query returned", detail: String(rooms.count) + " rooms")
        try Task.checkCancellation()
        FreoSiriTrace.record("room phrase received", detail: string)
        // Preserve ambiguous matches so Siri can ask which room was meant.
        return SiriRoomReference.matching(query: string, in: rooms).map(FreoRoomEntity.init)
    }
}

struct CleanRoomsIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean rooms"
    static let description = IntentDescription("Choose one or more of your robot's saved rooms and a cleaning mode. Uses Narwal's saved sign-in session, including while locked.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Cleaning mode", requestValueDialog: "Which cleaning mode would you like?")
    var mode: FreoIntentCleaningMode

    @Parameter(title: "Rooms", requestValueDialog: "Which rooms would you like to clean?")
    var rooms: [FreoRoomEntity]

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$mode) in \(\.$rooms)")
    }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        guard !rooms.isEmpty else { throw $rooms.needsValueError("Choose at least one saved room.") }
        let references = try rooms.map { try $0.checkedReference() }
        let reply = try await FreoStore.shared.siriStart(mode: mode.cleaningMode, references: references)
        return .result(dialog: "\(reply)")
    }
}

// App Shortcut trigger phrases accept one interpolated intent parameter. These
// thin, mode-specific intents let that parameter be a single dynamic room. The
// action above supports multi-room selections in the Shortcuts editor and prompts.
struct VacuumRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Vacuum a room"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Room", requestValueDialog: "Which room would you like to vacuum?")
    var room: FreoRoomEntity
    static var parameterSummary: some ParameterSummary { Summary("Vacuum \(\.$room)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        FreoSiriTrace.record("mode command perform", detail: "vacuum / " + room.name)
        try Task.checkCancellation()
        let reply = try await FreoStore.shared.siriStart(mode: .vacuum, references: [room.checkedReference()])
        return .result(dialog: "\(reply)")
    }
}

struct MopRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Mop a room"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Room", requestValueDialog: "Which room would you like to mop?")
    var room: FreoRoomEntity
    static var parameterSummary: some ParameterSummary { Summary("Mop \(\.$room)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        FreoSiriTrace.record("mode command perform", detail: "mop / " + room.name)
        try Task.checkCancellation()
        let reply = try await FreoStore.shared.siriStart(mode: .mop, references: [room.checkedReference()])
        return .result(dialog: "\(reply)")
    }
}

struct VacuumAndMopRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Vacuum and mop a room"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Room", requestValueDialog: "Which room would you like to vacuum and mop?")
    var room: FreoRoomEntity
    static var parameterSummary: some ParameterSummary { Summary("Vacuum and mop \(\.$room)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        FreoSiriTrace.record("mode command perform", detail: "vacuumMop / " + room.name)
        try Task.checkCancellation()
        let reply = try await FreoStore.shared.siriStart(mode: .vacuumMop, references: [room.checkedReference()])
        return .result(dialog: "\(reply)")
    }
}

struct VacuumThenMopRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Vacuum then mop a room"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Room", requestValueDialog: "Which room would you like to vacuum, then mop?")
    var room: FreoRoomEntity
    static var parameterSummary: some ParameterSummary { Summary("Vacuum then mop \(\.$room)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        FreoSiriTrace.record("mode command perform", detail: "vacuumThenMop / " + room.name)
        try Task.checkCancellation()
        let reply = try await FreoStore.shared.siriStart(mode: .vacuumThenMop, references: [room.checkedReference()])
        return .result(dialog: "\(reply)")
    }
}

struct PauseRobotIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause robot"
    static let description = IntentDescription("Pause the current cleaning task on your Narwal robot. Uses Narwal's saved sign-in session, including while locked.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var parameterSummary: some ParameterSummary { Summary("Pause robot") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        FreoSiriTrace.record("control command perform", detail: "pause")
        try Task.checkCancellation()
        let reply = try await FreoStore.shared.siriCommand(action: .pause)
        return .result(dialog: "\(reply)")
    }
}

struct StopRobotIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop robot"
    static let description = IntentDescription("Stop cleaning and return your Narwal robot to the dock. Uses Narwal's saved sign-in session, including while locked.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var parameterSummary: some ParameterSummary { Summary("Stop robot and return to dock") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        FreoSiriTrace.record("control command perform", detail: "dock")
        try Task.checkCancellation()
        let reply = try await FreoStore.shared.siriCommand(action: .dock)
        return .result(dialog: "\(reply)")
    }
}

struct FreoRoomOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [FreoRoomEntity] {
        try await FreoRoomQuery().suggestedEntities()
    }
}

/// A single dynamic parameter binds mode + room together in Siri's index.
/// This avoids competing near-identical phrase templates for the four modes.
struct FreoCleaningRequestEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room cleaning"
    static let defaultQuery = FreoCleaningRequestQuery()
    let mode: FreoIntentCleaningMode
    let room: FreoRoomEntity?
    var id: String { mode.rawValue + "|" + (room?.id ?? "choose-rooms") }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(spokenTitle)", synonyms: spokenVariants.dropFirst().map {
            LocalizedStringResource(stringLiteral: $0)
        })
    }
    private var modePhrases: [String] {
        switch mode {
        case .vacuum: return ["Vacuum", "Vacuum only"]
        case .mop: return ["Mop", "Mop only"]
        case .vacuumMop: return ["Vacuum and mop", "Vacuum & mop", "Vacuum and mop together"]
        case .vacuumThenMop: return ["Vacuum then mop", "Vacuum before mopping"]
        }
    }
    var spokenVariants: [String] {
        guard let room else { return modePhrases }
        return modePhrases.flatMap { [$0 + " " + room.name, $0 + " the " + room.name] }
    }
    var spokenTitle: String { modePhrases[0] + (room.map { " " + $0.name } ?? "") }

}
struct FreoCleaningRequestQuery: EntityStringQuery {
    func suggestedEntities() async throws -> [FreoCleaningRequestEntity] {
        FreoSiriTrace.record("command suggestions requested", detail: "Reading room catalog")
        let rooms = try await FreoRoomQuery().suggestedEntities()
        FreoSiriTrace.record("command suggestions returned", detail: String(rooms.count) + " rooms")
        return [FreoIntentCleaningMode.vacuum, .mop, .vacuumMop, .vacuumThenMop].flatMap { mode in
            [FreoCleaningRequestEntity(mode: mode, room: nil)] + rooms.map { FreoCleaningRequestEntity(mode: mode, room: $0) }
        }
    }
    func entities(for identifiers: [String]) async throws -> [FreoCleaningRequestEntity] {
        FreoSiriTrace.record("command identifiers requested", detail: String(identifiers.count))
        guard identifiers.count <= 400, Set(identifiers).count == identifiers.count else {
            throw ConnectorError.invalid("Invalid saved room cleaning selection.")
        }
        let entities = try await suggestedEntities()
        var resolved: [FreoCleaningRequestEntity] = []
        for id in identifiers {
            if let entity = entities.first(where: { $0.id == id }) { resolved.append(entity); continue }
            let parts = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  let mode = FreoIntentCleaningMode(rawValue: parts[0]) else {
                FreoSiriTrace.record("command identifier missing", detail: "Saved reference not present in current catalog")
                throw ConnectorError.invalid("The saved room changed. Choose its current name again.")
            }
            if parts[1] == "choose-rooms" { resolved.append(FreoCleaningRequestEntity(mode: mode, room: nil)); continue }
            let currentRooms = try await FreoStore.shared.siriRoomSuggestions()
            guard let room = try await FreoStore.shared.resolveSiriRoom(identifier: parts[1], current: currentRooms) else {
                FreoSiriTrace.record("command identifier missing", detail: "No unambiguous current room matches the saved selection")
                throw ConnectorError.invalid("This shortcut’s room changed. Open Narwal, reload rooms, and choose the current room again.")
            }
            resolved.append(FreoCleaningRequestEntity(mode: mode, room: FreoRoomEntity(room)))
        }
        return resolved
    }
    func entities(matching string: String) async throws -> [FreoCleaningRequestEntity] {
        FreoSiriTrace.record("command phrase received", detail: string)
        let query = Self.normalizedPhrase(string)
        guard !query.isEmpty else { return [] }
        // Retain mode words: "and" and "then" must never be interchangeable.
        let matches = try await suggestedEntities().filter { entity in
            entity.spokenVariants.contains { Self.normalizedPhrase($0) == query }
        }
        FreoSiriTrace.record("phrase lookup", detail: string + " -> " + String(matches.count) + " matches")
        return matches
    }
    private static func normalizedPhrase(_ string: String) -> String {
        let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return String(folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }.map(Character.init))

    }
}
struct FreoCleaningRequestOptionsProvider: DynamicOptionsProvider {
    let mode: FreoIntentCleaningMode
    func results() async throws -> [FreoCleaningRequestEntity] {
        try await FreoCleaningRequestQuery().suggestedEntities().filter { $0.mode == mode && $0.room != nil }
    }
}

struct RunRoomCleaningIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean a named room"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Room cleaning", requestValueDialog: "Which cleaning mode and room?")
    var request: FreoCleaningRequestEntity
    @Parameter(title: "Rooms", requestValueDialog: "Which rooms would you like to clean?")
    var rooms: [FreoRoomEntity]?
    static var parameterSummary: some ParameterSummary { Summary("\(\.$request)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        FreoSiriTrace.record("named command resolved", detail: request.spokenTitle)
        let chosen: [FreoRoomEntity]
        if let room = request.room { chosen = [room] }
        else if let rooms, !rooms.isEmpty { chosen = rooms }
        else {
            // Ask for only the missing rooms; the mode remains encoded in
            // request.id and is restored by the entity query on re-entry.
            throw $rooms.needsValueError("Which rooms would you like to clean?")
        }
        FreoSiriTrace.record("command ready", detail: request.mode.rawValue + " / " + chosen.map(\.name).joined(separator: ", "))
        let reply = try await FreoStore.shared.siriStart(mode: request.mode.cleaningMode,
                                                       references: chosen.map { try $0.checkedReference() })
        return .result(dialog: "\(reply)")
    }
}
/// Bounded private breadcrumbs for diagnosing Siri failures before robot I/O.
/// Contains stage/phrase text only, not tokens, passwords, or network payloads.
enum FreoSiriTrace {
    private static let lock = NSLock()
    private struct Entry: Codable { let date: Date; let stage: String; let detail: String }
    static func record(_ stage: String, detail: String) {
        #if os(iOS)
        lock.lock(); defer { lock.unlock() }
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FreoSiriDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent((stage.hasPrefix("command suggestions") || stage == "room query returned") ? "indexing.json" : "recent.json")
            var entries: [Entry] = []
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               attributes[.type] as? FileAttributeType == .typeRegular,
               let size = attributes[.size] as? NSNumber, size.intValue <= 32_768,
               let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
            entries.append(Entry(date: Date(), stage: stage, detail: String(detail.prefix(240))))
            let data = try JSONEncoder().encode(Array(entries.suffix(20)))
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var url = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch { NSLog("FreoSiri diagnostic write failed: %@", error.localizedDescription) }
        #endif
    }
}

struct FreoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        #if FREO_SIRI_STRING_PROBE
        AppShortcut(intent: FreoStringRoomProbeIntent(), phrases: [
            "Run \(.applicationName) text vacuum and mop"
        ], shortTitle: "Vacuum and mop by name", systemImageName: "drop",
            parameterPresentation: .init(for: \.$room, summary: .init("Vacuum and mop \(\.$room)")) {
                OptionsCollection(FreoStringRoomOptions(), title: "Rooms")
            })
        #else

        AppShortcut(intent: VacuumRoomIntent(), phrases: [
            "Run \(.applicationName) vacuum \(\.$room)",
            "Run \(.applicationName) robot vacuum \(\.$room)",
            "Use \(.applicationName) to vacuum \(\.$room)",
            "\(.applicationName) vacuum \(\.$room)",
            "Vacuum \(\.$room) with \(.applicationName)",
            "Run \(.applicationName) vacuum"
        ], shortTitle: "Vacuum", systemImageName: "wind")

        AppShortcut(intent: MopRoomIntent(), phrases: [
            "Run \(.applicationName) mop \(\.$room)",
            "Run \(.applicationName) robot mop \(\.$room)",
            "Use \(.applicationName) to mop \(\.$room)",
            "\(.applicationName) mop \(\.$room)",
            "Mop \(\.$room) with \(.applicationName)",
            "Run \(.applicationName) mop"
        ], shortTitle: "Mop", systemImageName: "drop")

        AppShortcut(intent: VacuumAndMopRoomIntent(), phrases: [
            "Run \(.applicationName) vacuum and mop \(\.$room)",
            "Run \(.applicationName) robot vacuum and mop \(\.$room)",
            "Use \(.applicationName) to vacuum and mop \(\.$room)",
            "\(.applicationName) vacuum and mop \(\.$room)",
            "Vacuum and mop \(\.$room) with \(.applicationName)",
            "Run \(.applicationName) vacuum and mop"
        ], shortTitle: "Vacuum and mop", systemImageName: "drop")

        AppShortcut(intent: VacuumThenMopRoomIntent(), phrases: [
            "Run \(.applicationName) vacuum then mop \(\.$room)",
            "Run \(.applicationName) robot vacuum then mop \(\.$room)",
            "Use \(.applicationName) to vacuum then mop \(\.$room)",
            "\(.applicationName) vacuum then mop \(\.$room)",
            "Vacuum then mop \(\.$room) with \(.applicationName)",
            "Run \(.applicationName) vacuum then mop"
        ], shortTitle: "Vacuum then mop", systemImageName: "arrow.right")

        AppShortcut(intent: PauseRobotIntent(), phrases: [
            "Pause \(.applicationName)",
            "Pause \(.applicationName) robot",
            "Run \(.applicationName) pause",
            "Run \(.applicationName) pause robot",
            "Use \(.applicationName) to pause",
            "Use \(.applicationName) to pause the robot",
            "\(.applicationName) pause",
            "Pause the robot with \(.applicationName)"
        ], shortTitle: "Pause robot", systemImageName: "pause.fill")

        AppShortcut(intent: StopRobotIntent(), phrases: [
            "Stop \(.applicationName)",
            "Stop \(.applicationName) robot",
            "Run \(.applicationName) stop",
            "Run \(.applicationName) stop robot",
            "Use \(.applicationName) to stop",
            "Use \(.applicationName) to stop the robot",
            "\(.applicationName) stop",
            "Stop the robot with \(.applicationName)",
            "Dock \(.applicationName)",
            "Return \(.applicationName) to dock"
        ], shortTitle: "Stop robot", systemImageName: "house")

        #endif
    }
}

#if DEBUG && FREO_SIRI_ROUTING_TESTS
/// Explicit UI-test lease: intercepts only Siri starts, never stores credentials.
/// Survives a Siri-triggered app relaunch; expires after thirty minutes.
enum FreoSiriRoutingTestMode {
    private static let key = "freo.siriRoutingTestUntil"
    private static let buildKey = "freo.siriRoutingTestBuild"
    private static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    static var isActive: Bool {
        guard !build.isEmpty, UserDefaults.standard.string(forKey: buildKey) == build else { return false }
        let remaining = UserDefaults.standard.double(forKey: key) - Date().timeIntervalSince1970
        return remaining > 0 && remaining <= 1800
    }
    static func configure(arguments: [String]) {
        if arguments.contains("--freo-end-siri-routing-test") {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: buildKey)
        } else if arguments.contains("--freo-siri-routing-test") {
            UserDefaults.standard.set(Date().timeIntervalSince1970 + 1800, forKey: key)
            UserDefaults.standard.set(build, forKey: buildKey)
        }
    }
    static func result(mode: CleaningMode, rooms: [String]) -> String {
        let sequence = UserDefaults.standard.integer(forKey: "freo.siriRoutingTestSequence") + 1
        UserDefaults.standard.set(sequence, forKey: "freo.siriRoutingTestSequence")
        return "Siri routing test \(sequence): \(mode.title) in \(rooms.joined(separator: ", "))."
    }
    static func actionResult(action: RobotAction) -> String {
        let sequence = UserDefaults.standard.integer(forKey: "freo.siriRoutingTestSequence") + 1
        UserDefaults.standard.set(sequence, forKey: "freo.siriRoutingTestSequence")
        let label = action == .pause ? "Pause robot" : "Stop and return to dock"
        return "Siri routing test \(sequence): \(label)."
    }
}
#endif
