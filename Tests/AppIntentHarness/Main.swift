import AppIntents
import Foundation

// This executable compiles the real AppIntents file with an in-memory store
// substitute. It cannot import NarwalService or make robot/network requests.
@MainActor final class FreoStore {
    static let shared = FreoStore()
    var catalog: [SiriRoomReference] = []
    private let roomCatalog = SiriRoomCatalog(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("FreoAppIntentHarness-\(UUID().uuidString)", isDirectory: true))
    var queryFailure: Error?
    var commandFailure: Error?
    var queryCount = 0
    var requests: [(CleaningMode, [SiriRoomReference])] = []
    var controlActions: [RobotAction] = []
    func reset(_ rooms: [SiriRoomReference]) {
        catalog = rooms; queryFailure = nil; commandFailure = nil
        queryCount = 0; requests = []; controlActions = []
        try? roomCatalog.save(rooms)
    }
    func siriRoomSuggestions() async throws -> [SiriRoomReference] { try await siriRooms() }
    func siriRooms() async throws -> [SiriRoomReference] {
        queryCount += 1
        if let queryFailure { throw queryFailure }
        return catalog
    }
    func resolveSiriRoom(identifier: String, current: [SiriRoomReference]) throws -> SiriRoomReference? {
        try roomCatalog.resolve(identifier: identifier, current: current)
    }
    func siriStart(mode: CleaningMode, references: [SiriRoomReference]) async throws -> String {
        let migrated = try roomCatalog.resolve(references, current: catalog)
        requests.append((mode, migrated))
        if let commandFailure { throw commandFailure }
        return "Request accepted by the test substitute."
    }
    func siriCommand(action: RobotAction) async throws -> String {
        controlActions.append(action)
        if let commandFailure { throw commandFailure }
        return action == .pause
            ? "Request accepted: Pause robot."
            : "Request accepted: Stop and return to dock."
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct AppIntentChecks {
    @MainActor static func main() async throws {
        let store = FreoStore.shared
        let rooms = ["Kitchen", "Hallway", "Sálon upstairs", "Laundry Room"].enumerated().map {
            SiriRoomReference(productKey: "EHf6cRNRGT", deviceID: String(repeating: "a", count: 32),
                mapID: 4, roomID: $0.offset + 1, name: $0.element, mapRevision: 38)
        }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw CheckFailure(description: message) }
        }
        func expectError(_ message: String, _ operation: () async throws -> Void) async throws {
            do { try await operation() }
            catch { return }
            throw CheckFailure(description: message)
        }
        let query = FreoRoomQuery()
        store.reset(rooms)
        let suggestions = try await query.suggestedEntities()
        try check(suggestions.map(\.id) == rooms.map(\.id), "Suggestions must use the actual catalog")
        let commandQuery = FreoCleaningRequestQuery()
        let commandEntities = try await commandQuery.suggestedEntities()
        try check(commandEntities.count == (rooms.count + 1) * 4, "One dynamic entity is needed per mode and actual room")
        for mode in [FreoIntentCleaningMode.vacuum, .mop, .vacuumMop, .vacuumThenMop] {
            let tiles = try await FreoCleaningRequestOptionsProvider(mode: mode).results()
            try check(tiles.count == rooms.count && tiles.allSatisfy { $0.mode == mode },
                      "Each shortcut section must contain its mode for every current room")
            try check(tiles.compactMap { $0.room?.id } == rooms.map(\.id), "Room shortcut tiles must use the actual catalog")
        }
        for (phrase, expected) in [("Vacuum Kitchen", FreoIntentCleaningMode.vacuum),
                                   ("Mop Kitchen", .mop), ("Vacuum and mop Kitchen", .vacuumMop),
                                   ("Vacuum then mop Kitchen", .vacuumThenMop)] {
            let matches = try await commandQuery.entities(matching: phrase)
            try check(matches.count == 1 && matches[0].mode == expected && matches[0].room?.id == rooms[0].id,
                      "One-shot mode or room was confused: " + phrase)
            let intent = RunRoomCleaningIntent(); intent.request = matches[0]
            _ = try await intent.perform()
            try check(store.requests.last?.0 == expected.cleaningMode && store.requests.last?.1 == [rooms[0]],
                      "Combined mode/room entity sent a different command")
        }
        try check(try await commandQuery.entities(matching: "Vacuum nonexistent").isEmpty,
                  "Unknown room must not match a different cleaning action")
        for (phrase, expected) in [("Vacuum & mop litterbox", FreoIntentCleaningMode.vacuumMop),
                                   ("vacuum and mop the litter box", .vacuumMop),
                                   ("vacuum then mop Laundry Room", .vacuumThenMop),
                                   ("Vacuum, then mop the litter-box.", .vacuumThenMop),
                                   ("Vacuum only litter box", .vacuum),
                                   ("Mop only litter box", .mop),
                                   ("Vacuum litter box", .vacuum)] {
            let matches = try await commandQuery.entities(matching: phrase)
            try check(matches.count == 1 && matches[0].mode == expected && matches[0].room?.id == rooms[3].id,
                      "Spoken multiword-room variant resolved incorrectly: " + phrase)
        }
        store.reset(rooms)
        for (phrase, expected) in [("Vacuum", FreoIntentCleaningMode.vacuum), ("Mop", .mop),
                                   ("Vacuum and mop", .vacuumMop), ("Vacuum then mop", .vacuumThenMop)] {
            let matches = try await commandQuery.entities(matching: phrase)
            try check(matches.count == 1 && matches[0].mode == expected && matches[0].room == nil,
                      "Mode-only request lost its selected mode")
            let pending = RunRoomCleaningIntent(); pending.request = matches[0]
            let sentBeforePrompt = store.requests.count
            try await expectError("Missing rooms must request a value instead of defaulting") { _ = try await pending.perform() }
            try check(store.requests.count == sentBeforePrompt, "A missing room sent a cleaning command")
            let restored = try await commandQuery.entities(for: [matches[0].id])
            let intent = RunRoomCleaningIntent(); intent.request = restored[0]; intent.rooms = [FreoRoomEntity(rooms[0])]
            _ = try await intent.perform()
            try check(store.requests.last?.0 == expected.cleaningMode && store.requests.last?.1 == [rooms[0]],
                      "Selecting a room after a mode-only command changed the mode")
        }
        store.reset(rooms)
        let selected = try await query.entities(for: [rooms[2].id, rooms[0].id])
        try check(selected.map(\.id) == [rooms[2].id, rooms[0].id], "Entity restoration changed selected rooms/order")
        try check(try await query.entities(matching: " SALON ").map(\.id) == [rooms[2].id], "Dynamic names must match case/diacritics/whitespace")
        try check(try await query.entities(matching: "nonexistent room").isEmpty, "An unknown name must not select all rooms")

        let sameName = SiriRoomReference(productKey: rooms[0].productKey, deviceID: rooms[0].deviceID,
            mapID: 4, roomID: 9, name: "Kitchen", mapRevision: 38)
        store.reset(rooms + [sameName])
        try check(try await query.entities(matching: "Kitchen").count == 2, "Ambiguous names must remain available for disambiguation")
        store.reset(rooms)
        try await expectError("A duplicate saved selection was accepted") { _ = try await query.entities(for: [rooms[0].id, rooms[0].id]) }
        try check(store.queryCount == 0, "Invalid query must fail before asking the store")
        let stale = SiriRoomReference(productKey: rooms[0].productKey, deviceID: rooms[0].deviceID,
            mapID: 4, roomID: 1, name: "Kitchen", mapRevision: 37)
        try await expectError("Stale revision entity was restored") { _ = try await query.entities(for: [stale.id]) }
        store.queryFailure = ConnectorError.invalid("Test session expired")
        try await expectError("A session/query error was hidden") { _ = try await query.suggestedEntities() }
        try check(store.requests.isEmpty, "Entity queries must not issue cleaning commands")

        let modes: [(FreoIntentCleaningMode, CleaningMode)] = [
            (.vacuum, .vacuum), (.mop, .mop), (.vacuumMop, .vacuumMop), (.vacuumThenMop, .vacuumThenMop)
        ]
        store.reset(rooms)
        for (intentMode, expectedMode) in modes {
            for mask in 1..<8 {
                let selectedRooms = rooms.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                let intent = CleanRoomsIntent()
                intent.mode = intentMode; intent.rooms = selectedRooms.map(FreoRoomEntity.init)
                _ = try await intent.perform()
                let sent = store.requests.last!
                try check(sent.0 == expectedMode && sent.1 == selectedRooms, "Mode or room subset changed in Clean rooms")
            }
        }
        try check(store.requests.count == 28, "One action must invoke one command path")

        store.reset(rooms)
        for room in rooms {
            let entity = FreoRoomEntity(room)
            let vacuum = VacuumRoomIntent(); vacuum.room = entity; _ = try await vacuum.perform()
            let mop = MopRoomIntent(); mop.room = entity; _ = try await mop.perform()
            let together = VacuumAndMopRoomIntent(); together.room = entity; _ = try await together.perform()
            let sequential = VacuumThenMopRoomIntent(); sequential.room = entity; _ = try await sequential.perform()
        }
        try check(store.requests.count == rooms.count * 4, "A single-room entry point repeated or omitted a request")
        for (index, sent) in store.requests.enumerated() {
            try check(sent.0 == modes[index % 4].1 && sent.1 == [rooms[index / 4]], "Single-room phrase mapped to the wrong command")
        }

        let priorMapRooms = rooms.enumerated().map {
            SiriRoomReference(productKey: $0.element.productKey, deviceID: $0.element.deviceID,
                mapID: $0.element.mapID, roomID: $0.offset + 30, name: $0.element.name, mapRevision: 37)
        }
        store.reset(priorMapRooms)
        store.reset(rooms)
        store.requests = []
        let roomQueryAfterEdit = FreoRoomQuery()
        let requestQueryAfterEdit = FreoCleaningRequestQuery()
        for (index, oldRoom) in priorMapRooms.enumerated() {
            let refreshedRoom = try await roomQueryAfterEdit.entities(for: [oldRoom.id])
            try check(refreshedRoom.count == 1 && refreshedRoom[0].id == rooms[index].id,
                      "A saved room parameter did not rehydrate after the map revision changed")
            for (intentMode, expectedMode) in modes {
                let oldRequest = FreoCleaningRequestEntity(mode: intentMode, room: FreoRoomEntity(oldRoom))
                let refreshedRequest = try await requestQueryAfterEdit.entities(for: [oldRequest.id])
                try check(refreshedRequest.count == 1 && refreshedRequest[0].mode == intentMode
                          && refreshedRequest[0].room?.id == rooms[index].id,
                          "A saved mode-and-room shortcut did not rehydrate after the map revision changed")
                let intent = RunRoomCleaningIntent(); intent.request = refreshedRequest[0]
                _ = try await intent.perform()
                try check(store.requests.last?.0 == expectedMode && store.requests.last?.1 == [rooms[index]],
                          "A rehydrated mode-and-room shortcut changed its target")
            }
        }
        try check(store.requests.count == rooms.count * 4, "Rehydrated mode-and-room shortcuts were not all sent")
        store.requests = []
        for oldRoom in priorMapRooms {
            let entity = FreoRoomEntity(oldRoom)
            let vacuum = VacuumRoomIntent(); vacuum.room = entity; _ = try await vacuum.perform()
            let mop = MopRoomIntent(); mop.room = entity; _ = try await mop.perform()
            let together = VacuumAndMopRoomIntent(); together.room = entity; _ = try await together.perform()
            let sequential = VacuumThenMopRoomIntent(); sequential.room = entity; _ = try await sequential.perform()
        }
        try check(store.requests.count == rooms.count * 4, "Stale shortcut migration omitted a mode or room")
        for (index, sent) in store.requests.enumerated() {
            try check(sent.0 == modes[index % 4].1 && sent.1 == [rooms[index / 4]],
                      "A saved room shortcut did not migrate to the matching current room")
        }

        if let fixture = ProcessInfo.processInfo.environment["FREO_SIRI_CATALOG_FIXTURE"] {
            struct Catalog: Decodable { let rooms: [SiriRoomReference] }
            let actual = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: URL(fileURLWithPath: fixture))).rooms
            try check(!actual.isEmpty && actual.count <= 12, "Matrix fixture must contain 1–12 actual rooms")
            store.reset(actual)
            for entity in try await commandQuery.suggestedEntities() where entity.room != nil {
                for phrase in entity.spokenVariants {
                    let matches = try await commandQuery.entities(matching: phrase)
                    try check(matches.count == 1 && matches[0].id == entity.id, "Actual catalog phrase failed: " + phrase)
                }
                let restored = try await commandQuery.entities(for: [entity.id])
                let intent = RunRoomCleaningIntent(); intent.request = restored[0]
                _ = try await intent.perform()
                try check(store.requests.last?.0 == entity.mode.cleaningMode && store.requests.last?.1 == [try entity.room!.checkedReference()],
                          "Actual room shortcut changed mode or room")
            }
            var combinations = 0
            for (intentMode, expectedMode) in modes {
                for mask in 1..<(1 << actual.count) {
                    let selection = actual.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                    let intent = CleanRoomsIntent(); intent.mode = intentMode; intent.rooms = selection.map(FreoRoomEntity.init)
                    _ = try await intent.perform()
                    try check(store.requests.last?.0 == expectedMode && store.requests.last?.1 == selection,
                              "Actual room subset changed at command boundary")
                    combinations += 1
                }
            }
            print("Actual room matrix passed: \(actual.count * 4) named commands and \(combinations) mode/room-subset commands; fake store only.")
        }

        store.reset(rooms)
        _ = try await PauseRobotIntent().perform()
        _ = try await StopRobotIntent().perform()
        try check(store.controlActions == [.pause, .dock] && store.requests.isEmpty,
                  "Pause and stop intents must dispatch pause and dock actions without starting a clean")

        store.reset(rooms)
        let empty = CleanRoomsIntent(); empty.mode = .vacuum; empty.rooms = []
        try await expectError("Empty room selection reached the store") { _ = try await empty.perform() }
        try check(store.requests.isEmpty, "Empty selection must not invoke cleaning")
        let uncertain = VacuumRoomIntent(); uncertain.room = FreoRoomEntity(rooms[0])
        store.commandFailure = ConnectorError.outcomeUnknown
        try await expectError("An uncertain command was reported as success") { _ = try await uncertain.perform() }
        try check(store.requests.count == 1, "An uncertain command must not be retried")
        try await expectError("An uncertain pause was reported as success") { _ = try await PauseRobotIntent().perform() }
        try await expectError("An uncertain stop was reported as success") { _ = try await StopRobotIntent().perform() }
        try check(store.controlActions == [.pause, .dock], "Uncertain pause/stop commands must not be retried")

        store.reset(rooms)
        let cancelled = Task { @MainActor in
            let intent = VacuumRoomIntent(); intent.room = FreoRoomEntity(rooms[0])
            _ = try await intent.perform()
        }
        cancelled.cancel()
        try await expectError("Cancelled intent continued") { try await cancelled.value }
        let cancelledPause = Task { @MainActor in _ = try await PauseRobotIntent().perform() }
        cancelledPause.cancel()
        try await expectError("Cancelled pause intent continued") { try await cancelledPause.value }
        let cancelledStop = Task { @MainActor in _ = try await StopRobotIntent().perform() }
        cancelledStop.cancel()
        try await expectError("Cancelled stop intent continued") { try await cancelledStop.value }
        try check(store.requests.isEmpty && store.controlActions.isEmpty, "Cancellation must not send a request")
        try check(!CleanRoomsIntent.openAppWhenRun && !VacuumRoomIntent.openAppWhenRun && !MopRoomIntent.openAppWhenRun
            && !VacuumAndMopRoomIntent.openAppWhenRun && !VacuumThenMopRoomIntent.openAppWhenRun
            && !RunRoomCleaningIntent.openAppWhenRun
            && !PauseRobotIntent.openAppWhenRun && !StopRobotIntent.openAppWhenRun, "Actions must run without opening the app so they work while locked")
        print("AppIntents harness passed: dynamic queries, 28 mode/subset actions, 16 single-room actions, pause/stop actions, stale/ambiguous/error/cancellation checks. No network or robot service linked.")
    }
}
