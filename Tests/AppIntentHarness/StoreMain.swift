import AppIntents
import Foundation

// Substitute only the service. The real FreoStore and FreoIntents are compiled
// unchanged; neither NarwalService.swift nor the network transport is linked.
@MainActor final class NarwalService {
    static let robot = RobotDevice(id: String(repeating: "a", count: 32), productKey: "EHf6cRNRGT", name: "Offline fixture")
    static var map = RoomMap(mapID: 4, rooms: [.init(id: 1, name: "Kitchen"), .init(id: 2, name: "Hallway")], mapRevision: 38)
    static var expiry: Date? = Date().addingTimeInterval(3600)
    static var networkExpiry = Date().addingTimeInterval(3600)
    static var remembered = false
    static var rememberedWrites: [Bool] = []
    static var rememberFailure: Error?
    static var forgetBeforeFailure = false
    static var signInRememberOptions: [Bool] = []
    static var restoreDevices: [RobotDevice]?
    static var restoreFailure: Error?
    static var restoreCalls = 0
    static var holdRestore = false
    static var heldRestore: CheckedContinuation<Void, Never>?
    static var statusReads = 0
    static var holdStatus = false
    static var heldStatus: CheckedContinuation<Void, Never>?
    static var statusReadInFlight = false
    static var holdMapSnapshot = false
    static var heldMapSnapshot: CheckedContinuation<Void, Never>?
    static var mapSnapshotInFlight = false
    static var disconnectCalls = 0
    static var disconnectFailure: Error?
    static var mapWriteAttempts = 0
    static var editableSnapshot: MapSnapshot?
    static var editableReads = 0
    static var editableFailure: Error?
    static var holdEditable = false
    static var heldEditable: CheckedContinuation<Void, Never>?
    static var mapEditResult: MapEditCommitResult?
    static var mapEditFailure: Error?
    static var mapEditOperations: [[RoomMapOperation]] = []
    static var mapReads = 0
    static var roomReadFailure: Error?
    static var commands: [(RobotAction, CleaningMode, [Int])] = []
    static var commandOptions: [CleaningOptions] = []
    static var commandFailure: Error?
    static var forgetSessionOnRequestFailure = false
    static var liveMap: LiveMapSnapshot?
    static var liveMapReads = 0
    static var workingCode = 1
    static var isPaused: Bool?
    static var statusTimestamp: Date?
    static var currentPlan = CleaningTaskSnapshot(resultCode: 2, mapID: nil, taskType: nil, optionFields: [:], samples: [])
    static var planReads = 0
    static var planFailure: Error?
    static var holdPlan = false
    static var heldPlan: CheckedContinuation<Void, Never>?
    static var capabilityReads = 0
    static var statusFailure: Error?
    static var expireDuringStatusRead = false
    static var expireDuringMapRead = false
    static var cloudRecords: [CloudCleaningRecord] = []
    static var cloudRun: CleaningRun?
    static var cloudPages: [Int] = []
    static var cloudHistoryFailure: Error?
    static var cloudDetailReads = 0
    static var holdCloudDetail = false
    static var heldCloudDetail: CheckedContinuation<Void, Never>?
    static var liveSubscriptions = 0
    static var liveCancellations = 0
    static var liveFailure: Error?
    static var liveHandler: (@Sendable (LiveTelemetryEvent) async throws -> Void)?
    static var liveWaiter: CheckedContinuation<Void, Error>?
    static var liveSubscriptionID: UUID?
    static var holdLivePreparation = false
    static var livePreparing = false
    static var livePreparationCancelled = false
    static var heldLivePreparation: CheckedContinuation<Void, Never>?
    static var preparationBusyRejections = 0
    static func reset(expired: Bool = false) {
        map = RoomMap(mapID: 4, rooms: [.init(id: 1, name: "Kitchen"), .init(id: 2, name: "Hallway")], mapRevision: 38)
        expiry = Date().addingTimeInterval(expired ? -1 : 3600)
        networkExpiry = Date().addingTimeInterval(3600)
        remembered = false; rememberedWrites = []; rememberFailure = nil; forgetBeforeFailure = false; signInRememberOptions = []
        restoreDevices = nil; restoreFailure = nil; restoreCalls = 0; holdRestore = false; heldRestore = nil
        statusReads = 0; holdStatus = false; heldStatus = nil; statusReadInFlight = false
        holdMapSnapshot = false; heldMapSnapshot = nil; mapSnapshotInFlight = false
        disconnectCalls = 0; disconnectFailure = nil; mapWriteAttempts = 0
        editableSnapshot = nil; editableReads = 0; editableFailure = nil; holdEditable = false; heldEditable = nil
        mapEditResult = nil; mapEditFailure = nil; mapEditOperations = []
        mapReads = 0; roomReadFailure = nil; commands = []; commandOptions = []; commandFailure = nil; forgetSessionOnRequestFailure = false
        liveMap = nil; liveMapReads = 0; workingCode = 1
        isPaused = nil; statusTimestamp = nil
        currentPlan = .init(resultCode: 2, mapID: nil, taskType: nil, optionFields: [:], samples: [])
        planReads = 0; planFailure = nil; holdPlan = false; heldPlan = nil; capabilityReads = 0
        statusFailure = nil; expireDuringStatusRead = false; expireDuringMapRead = false
        cloudRecords = []; cloudRun = nil; cloudPages = []; cloudDetailReads = 0; cloudHistoryFailure = nil
        holdCloudDetail = false; heldCloudDetail = nil
        liveSubscriptions = 0; liveCancellations = 0; liveFailure = nil
        liveHandler = nil; liveWaiter = nil; liveSubscriptionID = nil
        holdLivePreparation = false; livePreparing = false; livePreparationCancelled = false
        heldLivePreparation = nil; preparationBusyRejections = 0
    }
    func signIn(email: String, password: String, rememberSession: Bool = false) async throws -> [RobotDevice] {
        Self.signInRememberOptions.append(rememberSession)
        Self.remembered = rememberSession
        return [Self.robot]
    }
    func restoreSession() async throws -> [RobotDevice]? {
        Self.restoreCalls += 1
        if Self.holdRestore { await withCheckedContinuation { Self.heldRestore = $0 } }
        try Task.checkCancellation()
        if let failure = Self.restoreFailure { throw failure }
        return Self.restoreDevices
    }
    func networkExpiration() async -> Date { Self.networkExpiry }
    func isSessionRemembered() async -> Bool { Self.remembered }
    func setSessionRemembered(_ value: Bool) async throws {
        Self.rememberedWrites.append(value)
        if let failure = Self.rememberFailure {
            if !value && Self.forgetBeforeFailure { Self.remembered = false }
            throw failure
        }
        Self.remembered = value
    }
    func sessionExpiration() async -> Date? { Self.expiry }
    func disconnect() async throws {
        Self.disconnectCalls += 1; Self.expiry = nil
        Self.remembered = false; Self.restoreDevices = nil
        if let failure = Self.disconnectFailure { throw failure }
    }
    func status(device: RobotDevice) async throws -> RobotStatus {
        try Self.checkLivePreparation()
        Self.statusReads += 1
        Self.statusReadInFlight = true
        defer { Self.statusReadInFlight = false }
        if Self.holdStatus { await withCheckedContinuation { Self.heldStatus = $0 } }
        try Task.checkCancellation()
        if Self.expireDuringStatusRead { Self.expiry = nil; throw ConnectorError.invalid("Synthetic expired session") }
        if let failure = Self.statusFailure {
            if Self.forgetSessionOnRequestFailure { Self.remembered = false }
            throw failure
        }
        return .init(battery: 80, workingCode: Self.workingCode, isPaused: Self.isPaused, updatedAt: Self.statusTimestamp ?? Date())
    }
    func loadRooms(device: RobotDevice) async throws -> RoomMap {
        try Self.checkLivePreparation()
        Self.mapReads += 1
        if let failure = Self.roomReadFailure {
            if Self.forgetSessionOnRequestFailure { Self.remembered = false }
            throw failure
        }
        return Self.map
    }
    func command(device: RobotDevice, action: RobotAction, mode: CleaningMode, roomIDs: [Int], options: CleaningOptions = .standard) async throws -> CommandAcknowledgement {
        precondition(!Self.statusReadInFlight && !Self.mapSnapshotInFlight, "Commands must wait for silent reads")
        Self.commands.append((action, mode, roomIDs))
        Self.commandOptions.append(options)
        if let error = Self.commandFailure {
            if Self.forgetSessionOnRequestFailure { Self.remembered = false }
            throw error
        }
        return .init(accepted: true, resultCode: 1)
    }
    func recheckNetwork() async throws -> Date { Date().addingTimeInterval(3600) }
    func floorplan(device: RobotDevice) async throws -> Floorplan { throw unused() }
    func liveMapSnapshot(device: RobotDevice) async throws -> LiveMapSnapshot {
        Self.liveMapReads += 1
        Self.mapSnapshotInFlight = true
        defer { Self.mapSnapshotInFlight = false }
        if Self.holdMapSnapshot { await withCheckedContinuation { Self.heldMapSnapshot = $0 } }
        try Task.checkCancellation()
        if Self.expireDuringMapRead { Self.expiry = nil; throw unused() }
        guard let map = Self.liveMap else { throw unused() }
        return map
    }
    func observeLiveWindow(device: RobotDevice, baseline: LiveMapSnapshot,
                           onEvent: @escaping @Sendable (LiveTelemetryEvent) async throws -> Void) async throws {
        let id = UUID(); Self.liveSubscriptionID = id
        Self.liveSubscriptions += 1
        if Self.holdLivePreparation {
            Self.livePreparing = true
            await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { Self.heldLivePreparation = $0 }
            }, onCancel: {
                Task { @MainActor in Self.livePreparationCancelled = true }
            })
            Self.livePreparing = false
            try Task.checkCancellation()
        }
        if let failure = Self.liveFailure { throw failure }
        Self.liveHandler = onEvent
        defer {
            if Self.liveSubscriptionID == id { Self.liveHandler = nil; Self.liveWaiter = nil; Self.liveSubscriptionID = nil }
        }
        try await onEvent(.activated(leaseMilliseconds: 60_000, intervalMilliseconds: 2000))
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { Self.liveWaiter = $0 }
        }, onCancel: {
            Task { @MainActor in
                guard Self.liveSubscriptionID == id else { return }
                Self.liveCancellations += 1
                let waiter = Self.liveWaiter; Self.liveWaiter = nil
                waiter?.resume(throwing: CancellationError())
            }
        })
    }
    func history(device: RobotDevice, page: Int) async throws -> [CloudCleaningRecord] {
        Self.cloudPages.append(page)
        if let failure = Self.cloudHistoryFailure { throw failure }
        return page == 1 ? Self.cloudRecords : []
    }
    func historicalRoute(device: RobotDevice, record: CloudCleaningRecord) async throws -> CleaningRun {
        Self.cloudDetailReads += 1
        if Self.holdCloudDetail {
            // Deliberately wait for explicit cleanup even after cancellation,
            // like a transport whose cancellation callback is still unwinding.
            await withCheckedContinuation { Self.heldCloudDetail = $0 }
            try Task.checkCancellation()
        }
        guard let run = Self.cloudRun, record.matches(device: device) else { throw unused() }
        return run
    }
    private static func checkLivePreparation() throws {
        if livePreparing {
            preparationBusyRejections += 1
            throw ConnectorError.invalid("Another request is running.")
        }
    }
    func plan(device: RobotDevice) async throws -> CleaningTaskSnapshot {
        try Self.checkLivePreparation()
        Self.planReads += 1
        if Self.holdPlan { await withCheckedContinuation { Self.heldPlan = $0 } }
        try Task.checkCancellation()
        if let error = Self.planFailure { throw error }
        return Self.currentPlan
    }
    func sweepIntensitySupport(device: RobotDevice) async throws -> Bool? { Self.capabilityReads += 1; return nil }
    func editableMapSnapshot(device: RobotDevice, mapID: Int) async throws -> MapSnapshot {
        Self.editableReads += 1
        if Self.holdEditable { await withCheckedContinuation { Self.heldEditable = $0 } }
        try Task.checkCancellation()
        if let error = Self.editableFailure { throw error }
        guard let snapshot = Self.editableSnapshot else { throw unused() }
        return snapshot
    }
    func applyRoomOperations(device: RobotDevice, baseline: MapSnapshot, operations: [RoomMapOperation]) async throws -> MapEditCommitResult {
        Self.mapWriteAttempts += 1
        Self.mapEditOperations.append(operations)
        if let error = Self.mapEditFailure { throw error }
        guard let result = Self.mapEditResult else { throw unused() }
        Self.editableSnapshot = result.snapshot
        return result
    }
    private func unused() -> ConnectorError { .invalid("This offline intent test does not permit map editing or unrelated requests.") }
}

@main struct StoreIntentChecks {
    @MainActor static func main() async throws {
        let store = FreoStore.shared
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
        }
        func connect(expired: Bool = false) async {
            if store.isDemo { store.setDemo(false) }
            NarwalService.reset(expired: expired)
            await store.signIn(email: "fixture@example.invalid", password: "unused fixture")
        }
        func fails(_ operation: () async throws -> Void) async -> Bool {
            do { try await operation(); return false } catch { return true }
        }
        let catalogDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: catalogDirectory) }
        let catalog = SiriRoomCatalog(directory: catalogDirectory)
        let savedRoom = SiriRoomReference(productKey: NarwalService.robot.productKey,
            deviceID: NarwalService.robot.id, mapID: 4, roomID: 1, name: "entryway", mapRevision: 38)
        try catalog.save([savedRoom])
        NarwalService.reset()
        let coldStore = FreoStore(siriCatalog: catalog)
        let coldSuggestions = try await coldStore.siriRoomSuggestions()
        check(coldSuggestions == [savedRoom] && !coldStore.isAuthenticated,
              "Cold Siri indexing must use saved names without authenticating")
        check(NarwalService.restoreCalls == 0 && NarwalService.statusReads == 0 && NarwalService.mapReads == 0,
              "Siri indexing must never wait for cloud/session/status/map traffic")
        check(await fails { _ = try await coldStore.siriStart(mode: .vacuum, references: coldSuggestions) },
              "Cached suggestions must not authorize cleaning without a session")
        check(NarwalService.commands.isEmpty, "Cached suggestions sent a robot command")
        coldStore.disconnect()
        while coldStore.isBusy { await Task.yield() }
        check(try catalog.load().isEmpty, "Sign out must remove Siri's saved room catalog")
        NarwalService.reset()
        let missing = try await FreoStore(siriCatalog: catalog).siriRoomSuggestions()
        check(missing.isEmpty && NarwalService.restoreCalls == 0 && NarwalService.mapReads == 0,
              "Missing catalog must not restore authentication or read the cloud during OS indexing")
        try catalog.save([savedRoom])
        NarwalService.reset()
        NarwalService.restoreDevices = [NarwalService.robot]
        NarwalService.holdStatus = true
        let restoringStore = FreoStore(siriCatalog: catalog)
        let restoring = Task { await restoringStore.restoreSavedSessionIfNeeded() }
        while !NarwalService.statusReadInFlight { await Task.yield() }
        check(try catalog.load() == [savedRoom],
              "Restoring the same robot must keep Siri names available while status is loading")
        NarwalService.holdStatus = false
        NarwalService.heldStatus?.resume(); NarwalService.heldStatus = nil
        await restoring.value
        restoringStore.disconnect()
        while restoringStore.isBusy { await Task.yield() }
        check(try catalog.load().isEmpty, "Explicit sign-out must still remove retained startup room names")
        print("Cold Siri indexing checks passed: offline names, no cloud restoration, no command authorization, sign-out removal.")
        await connect()
        let entities = try await FreoRoomQuery().suggestedEntities()
        check(entities.map(\.name) == ["Kitchen", "Hallway"], "Query must load real-store room presentation")
        let modes: [(FreoIntentCleaningMode, CleaningMode)] = [(.vacuum, .vacuum), (.mop, .mop), (.vacuumMop, .vacuumMop), (.vacuumThenMop, .vacuumThenMop)]
        for (intentMode, expected) in modes {
            for selection in [[entities[0]], [entities[1]], entities] {
                let reads = NarwalService.mapReads, sent = NarwalService.commands.count
                let intent = CleanRoomsIntent(); intent.mode = intentMode; intent.rooms = selection
                _ = try await intent.perform()
                check(NarwalService.mapReads == reads + 1, "Every invocation must reread the map before start")
                check(NarwalService.commands.count == sent + 1, "Every action must send exactly once")
                let command = NarwalService.commands.last!
                check(command.0 == .start && command.1 == expected, "Intent mode/start changed at the store boundary")
                let selectedIDs = try selection.map { try $0.checkedReference().roomID }
                check(command.2 == selectedIDs, "The command targeted different rooms")
            }
        }
        check(store.message.hasPrefix("Request accepted") && !store.message.lowercased().contains("completed"), "Acceptance must not claim completed cleaning")

        let readsBeforeControls = NarwalService.mapReads
        let commandsBeforeControls = NarwalService.commands.count
        store.selectedTab = 1
        _ = try await PauseRobotIntent().perform()
        check(NarwalService.mapReads == readsBeforeControls && NarwalService.commands.count == commandsBeforeControls + 1,
              "Pause shortcut must send one pause command without rereading the map")
        check(NarwalService.commands.last?.0 == .pause && NarwalService.commands.last?.2 == [] &&
              store.selectedTab == 0 && store.message == "Request accepted: Pause robot.",
              "Pause shortcut must target the Robot tab and report pause acceptance")
        store.selectedTab = 1
        _ = try await StopRobotIntent().perform()
        check(NarwalService.mapReads == readsBeforeControls && NarwalService.commands.count == commandsBeforeControls + 2,
              "Stop shortcut must send one dock command without rereading the map")
        check(NarwalService.commands.last?.0 == .dock && NarwalService.commands.last?.2 == [] &&
              store.selectedTab == 0 && store.message == "Request accepted: Stop and return to dock.",
              "Stop shortcut must target the Robot tab and report stop/dock acceptance")

        await connect()
        await store.loadRooms()
        store.selectAllRooms()
        store.cleaningOptions = CleaningOptions(passes: 2, suction: .strong, humidity: .wet, route: .intensive)
        let selectedOptions = store.cleaningOptions
        store.setDemo(true)
        check(store.cleaningOptions == .standard, "Demo must start with independent options")
        store.cleaningOptions.suction = .quiet
        store.setDemo(false)
        check(store.cleaningOptions == selectedOptions, "Demo options must not change the live selection")
        await store.send(action: .start)
        check(NarwalService.commandOptions.last == selectedOptions, "Dashboard must send the reviewed cleaning options")
        let optionEntities = try await FreoRoomQuery().suggestedEntities()
        let defaultIntent = VacuumRoomIntent(); defaultIntent.room = optionEntities[0]
        _ = try await defaultIntent.perform()
        check(NarwalService.commandOptions.last == .standard && store.cleaningOptions == .standard,
              "Siri's standard action must not silently inherit a prior UI custom preset")

        await connect()
        let beforeRevision = try await FreoRoomQuery().suggestedEntities()
        NarwalService.map = RoomMap(mapID: 4, rooms: NarwalService.map.rooms, mapRevision: 39)
        let stale = VacuumRoomIntent(); stale.room = beforeRevision[0]
        check(await fails { _ = try await stale.perform() }, "A stale saved entity was accepted")
        check(NarwalService.commands.isEmpty && store.selectedRoomIDs.isEmpty, "Stale revision must send nothing and clear stale selection")

        await connect()
        let beforeDeletion = try await FreoRoomQuery().suggestedEntities()
        NarwalService.map = RoomMap(mapID: 4, rooms: [.init(id: 2, name: "Hallway")], mapRevision: 38)
        let deleted = MopRoomIntent(); deleted.room = beforeDeletion[0]
        check(await fails { _ = try await deleted.perform() }, "Deleted room was accepted")
        check(NarwalService.commands.isEmpty, "Deleted room must send nothing")

        await connect(expired: true)
        check(await fails { _ = try await FreoRoomQuery().suggestedEntities() }, "Expired session still resolves rooms")
        check(await fails { _ = try await PauseRobotIntent().perform() }, "Expired session still pauses robot")
        check(await fails { _ = try await StopRobotIntent().perform() }, "Expired session still stops robot")
        check(!store.isAuthenticated && store.selectedTab == 2 && store.message.contains("Sign in"), "Expired Siri session must reveal Connection")
        check(NarwalService.mapReads == 0 && NarwalService.commands.isEmpty, "Expired session must make no request")

        await connect()
        store.setDemo(true)
        check(await fails { _ = try await FreoRoomQuery().suggestedEntities() }, "Demo may not become a live Siri action")
        check(await fails { _ = try await PauseRobotIntent().perform() }, "Demo may not pause a live robot via Siri")
        check(await fails { _ = try await StopRobotIntent().perform() }, "Demo may not stop a live robot via Siri")
        check(NarwalService.mapReads == 0 && NarwalService.commands.isEmpty, "Demo Siri query must make no request")

        await connect()
        let current = try await FreoRoomQuery().suggestedEntities()
        NarwalService.commandFailure = ConnectorError.outcomeUnknown
        let uncertain = VacuumThenMopRoomIntent(); uncertain.room = current[0]
        check(await fails { _ = try await uncertain.perform() }, "Uncertain command must report an error")
        check(NarwalService.commands.count == 1 && store.message.contains("unknown"), "Uncertain command must not retry or report success")
        check(await fails { _ = try await PauseRobotIntent().perform() }, "Uncertain pause must report an error")
        check(NarwalService.commands.count == 2 && store.message.contains("unknown"), "Uncertain pause must not retry or report success")
        check(await fails { _ = try await StopRobotIntent().perform() }, "Uncertain stop must report an error")
        check(NarwalService.commands.count == 3 && store.message.contains("unknown"), "Uncertain stop must not retry or report success")
        print("Real-store AppIntents checks passed: 12 mode/room combinations; fresh-map read per action; revision/deletion/session/demo rejection; one uncertain send with no retry. Fake service only.")

        let historyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("freo-route-store-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let recorder = FreoStore(historyStore: CleaningHistoryStore(directory: historyDirectory))
        NarwalService.reset(); NarwalService.workingCode = 2
        await recorder.signIn(email: "fixture@example.invalid", password: "unused fixture")
        func observation(at: Date, points: [RobotPathPoint], runtimeBits: UInt32 = 0) -> LiveMapSnapshot {
            let floorplan = Floorplan(mapID: 4, width: 10, height: 10, resolution: 60,
                rooms: NarwalService.map.rooms, pixels: Array(repeating: 0x101 ^ runtimeBits, count: 100), mapRevision: 38)
            let snapshot = MapSnapshot(productKey: NarwalService.robot.productKey, deviceID: NarwalService.robot.id,
                mapID: 4, mapVersion: 1, editVersion: 38, capturedAt: at, floorplan: floorplan, staticMapPayload: Data())
            let route = RobotTrajectory(productKey: snapshot.productKey, deviceID: snapshot.deviceID,
                mapID: 4, mapVersion: 1, editVersion: 38, points: points,
                segments: [.init(id: 0, typeCode: 4, points: points)], pose: .init(point: points.last!),
                capturedAt: at, deviceTimestampMilliseconds: UInt64(at.timeIntervalSince1970 * 1000),
                sequenceID: UInt64(at.timeIntervalSince1970))
            return LiveMapSnapshot(snapshot: snapshot, trajectory: route)
        }
        let firstTime = Date(), firstPoints = [RobotPathPoint(x: 1, y: 1), .init(x: 2, y: 2)]
        NarwalService.liveMap = observation(at: firstTime, points: firstPoints)
        await recorder.refreshStatus()
        check(recorder.trajectory?.points == firstPoints && recorder.cleaningHistory.count == 1,
              "Read-only refresh must display and privately save observed paths")
        check(recorder.cleaningHistory[0].modeName == nil && recorder.cleaningHistory[0].roomNames.isEmpty,
              "Current picker values must never become observed route metadata")
        let firstID = recorder.cleaningHistory[0].id
        await recorder.loadCleaningHistory()
        NarwalService.liveMap = observation(at: firstTime.addingTimeInterval(15),
            points: firstPoints + [.init(x: 3, y: 3)], runtimeBits: 0x10010003)
        await recorder.refreshStatus()
        check(recorder.cleaningHistory.count == 1 && recorder.cleaningHistory[0].id == firstID,
              "Opening history and dynamic map bits must not fragment one captured route")
        check(NarwalService.commands.isEmpty && NarwalService.liveMapReads == 2,
              "Path refresh must only read; no cleaning or map command may be sent")
        recorder.setDemo(true)
        await recorder.refreshStatus()
        check(NarwalService.liveMapReads == 2 && recorder.trajectory == nil,
              "Demo must not fetch or expose a live path")
        recorder.setDemo(false)
        NarwalService.workingCode = 1
        NarwalService.liveMap = observation(at: firstTime.addingTimeInterval(30),
            points: firstPoints + [.init(x: 4, y: 4)])
        await recorder.refreshStatus()
        check(recorder.cleaningHistory[0].trajectory.points.count == 3,
              "An idle read must not be archived as another cleaning")
        await recorder.deleteCleaningRun(id: firstID)
        check(recorder.cleaningHistory.isEmpty && NarwalService.commands.isEmpty,
              "Deleting local history must not affect the robot")
        NarwalService.statusFailure = ConnectorError.invalid("Synthetic status read failure")
        await recorder.refreshStatus()
        check(!recorder.trajectoryError.isEmpty && recorder.trajectory != nil,
              "A failed status read must mark the retained route stale")
        NarwalService.statusFailure = nil; NarwalService.expireDuringMapRead = true
        await recorder.refreshStatus()
        check(!recorder.isAuthenticated && recorder.trajectory == nil && recorder.floorplan == nil,
              "Expiry during a map read must clear the stale authenticated presentation")
        check(NarwalService.commands.isEmpty, "Read errors must never send or retry a robot command")
        print("Route store checks passed: read-only recording, cumulative growth, history-view continuity, runtime bits, demo isolation, idle suppression, local deletion, stale reads, and mid-read expiry. Synthetic fixtures only.")

        NarwalService.reset()
        await recorder.signIn(email: "fixture@example.invalid", password: "unused fixture")
        let recordID = "9223372036854775000", ended = Date().addingTimeInterval(-3600)
        let cloudRecord = CloudCleaningRecord(id: recordID, productKey: NarwalService.robot.productKey,
            deviceID: NarwalService.robot.id, startedAt: ended.addingTimeInterval(-600), endedAt: ended,
            modeName: "Vacuum", roomNames: ["Kitchen"], mapID: 4)
        let archivedMap = Floorplan(mapID: 4, width: 10, height: 10, resolution: 60,
            rooms: NarwalService.map.rooms, pixels: Array(repeating: 0x101, count: 100))
        let archivedPath = RobotTrajectory(productKey: NarwalService.robot.productKey, deviceID: NarwalService.robot.id,
            mapID: 4, mapVersion: 1, editVersion: nil, points: firstPoints,
            segments: [.init(id: 0, typeCode: 0, points: firstPoints)], pose: nil, capturedAt: ended,
            deviceTimestampMilliseconds: nil, sequenceID: nil)
        let cloudRun = CleaningRun(id: NarwalHistoryCodec.stableID(productKey: NarwalService.robot.productKey,
            deviceID: NarwalService.robot.id, recordID: recordID), startedAt: cloudRecord.startedAt,
            updatedAt: ended, floorplan: archivedMap, trajectory: archivedPath,
            modeName: "Vacuum", roomNames: ["Kitchen"], partialReason: CleaningHistoryStore.cloudSavedReason,
            cloudRecordID: recordID, importedAt: Date())
        NarwalService.cloudRecords = [cloudRecord]; NarwalService.cloudRun = cloudRun
        await recorder.loadCloudHistory()
        check(recorder.cloudCleaningRecords.count == 1 && recorder.cleaningHistory.count == 1 &&
              recorder.cleaningHistory[0].cloudRecordID == recordID && NarwalService.cloudDetailReads == 1,
              "Cloud sync must save each exact-ID returned record without sending robot commands")
        let cached = await recorder.openCloudCleaningRecord(cloudRecord)
        check(cached?.id == cloudRun.id && NarwalService.cloudDetailReads == 1,
              "Opening a cached completed record must work without another request")
        await recorder.loadCloudHistory()
        check(NarwalService.cloudDetailReads == 1 && recorder.cleaningHistory.count == 1,
              "Repeated sync must deduplicate archived records")
        await recorder.loadCloudHistory(loadMore: true)
        check(NarwalService.cloudPages == [1, 1, 2] && !recorder.hasMoreCloudHistory,
              "Older records must use explicit pagination and stop on an empty page")
        recorder.setDemo(true)
        await recorder.loadCloudHistory()
        check(NarwalService.cloudPages.count == 3 && NarwalService.commands.isEmpty,
              "Cloud history must not run in demo or publish any robot control")
        print("Cloud history store checks passed: exact 64-bit identity, read-only page sync, local saving, cache reuse, deduplication, pagination, and demo isolation.")

        recorder.setDemo(false)
        NarwalService.cloudRecords = (1...3).map { index in
            CloudCleaningRecord(id: String(index), productKey: NarwalService.robot.productKey,
                deviceID: NarwalService.robot.id, startedAt: ended.addingTimeInterval(-600), endedAt: ended)
        }
        NarwalService.holdCloudDetail = true
        let readsBeforeCancel = NarwalService.cloudDetailReads
        let savedBeforeCancel = recorder.cleaningHistory
        let sync = Task { await recorder.loadCloudHistory() }
        for _ in 0..<10_000 {
            if NarwalService.heldCloudDetail != nil { break }
            await Task.yield()
        }
        check(NarwalService.heldCloudDetail != nil && recorder.isBusy && recorder.isCloudHistoryLoading,
              "The cancellation test must suspend a real Store sync inside its first fake detail request")
        recorder.cancelCloudHistorySync()
        recorder.cancelCloudHistorySync()
        check(recorder.isCloudHistoryCancelling && recorder.isBusy && recorder.isCloudHistoryLoading,
              "Cancel must remain busy until the in-flight read has safely unwound")
        NarwalService.holdCloudDetail = false
        NarwalService.heldCloudDetail?.resume(); NarwalService.heldCloudDetail = nil
        await sync.value
        check(!recorder.isBusy && !recorder.isCloudHistoryLoading && !recorder.isCloudHistoryCancelling,
              "Cancelled history sync must release the controls after cleanup")
        check(NarwalService.cloudDetailReads == readsBeforeCancel + 1 && recorder.cleaningHistory == savedBeforeCancel,
              "Cancellation must stop before the next download and preserve paths already saved")
        check(recorder.cloudHistoryError.isEmpty && NarwalService.commands.isEmpty,
              "User cancellation must finish quietly and never send a robot command")
        recorder.cancelCloudHistorySync()
        check(!recorder.isCloudHistoryCancelling, "Cancel after completion must be a no-op")

        NarwalService.holdCloudDetail = true
        let readsBeforeParentCancel = NarwalService.cloudDetailReads
        let callerCancelledSync = Task { await recorder.loadCloudHistory() }
        for _ in 0..<10_000 {
            if NarwalService.heldCloudDetail != nil { break }
            await Task.yield()
        }
        check(NarwalService.heldCloudDetail != nil, "The parent-cancellation check must reach the in-flight read")
        callerCancelledSync.cancel()
        check(recorder.isBusy, "Caller cancellation must also wait for transport cleanup")
        NarwalService.holdCloudDetail = false
        NarwalService.heldCloudDetail?.resume(); NarwalService.heldCloudDetail = nil
        await callerCancelledSync.value
        check(!recorder.isBusy && !recorder.isCloudHistoryLoading && !recorder.isCloudHistoryCancelling &&
              NarwalService.cloudDetailReads == readsBeforeParentCancel + 1,
              "Cancellation of the caller must propagate to the owned sync task and release controls")
        check(NarwalService.commands.isEmpty, "No cancellation path may send a robot command")

        NarwalService.holdStatus = true
        let backgroundStatus = Task { await recorder.refreshStatus(quiet: true) }
        for _ in 0..<10_000 {
            if NarwalService.heldStatus != nil { break }
            await Task.yield()
        }
        check(NarwalService.heldStatus != nil && !recorder.isBusy,
              "The queued-cancellation test must hold a silent background read")
        let pagesBeforeQueuedCancel = NarwalService.cloudPages
        let readsBeforeQueuedCancel = NarwalService.cloudDetailReads
        let waitingSync = Task { await recorder.loadCloudHistory() }
        for _ in 0..<10_000 {
            if recorder.isCloudHistoryLoading { break }
            await Task.yield()
        }
        check(recorder.isCloudHistoryLoading && recorder.isBusy,
              "History sync must reserve the command slot while waiting for the silent read")
        recorder.cancelCloudHistorySync()
        check(recorder.isCloudHistoryCancelling && recorder.isBusy && NarwalService.statusReadInFlight,
              "Cancel while queued must be acknowledged without releasing the occupied service slot")
        for _ in 0..<100 { await Task.yield() }
        check(recorder.isBusy && NarwalService.cloudPages == pagesBeforeQueuedCancel,
              "Queued cancellation must wait for cleanup and must not start a history request")
        NarwalService.holdStatus = false
        NarwalService.heldStatus?.resume(); NarwalService.heldStatus = nil
        await backgroundStatus.value
        await waitingSync.value
        check(!recorder.isBusy && !recorder.isCloudHistoryLoading && !recorder.isCloudHistoryCancelling &&
              recorder.cloudHistoryError.isEmpty && NarwalService.cloudPages == pagesBeforeQueuedCancel &&
              NarwalService.cloudDetailReads == readsBeforeQueuedCancel && recorder.cleaningHistory == savedBeforeCancel,
              "Queued cancellation must unwind quietly without history traffic or cached-path changes")

        NarwalService.cloudHistoryFailure = ConnectorError.invalid("Synthetic history download failure")
        await recorder.loadCloudHistory()
        check(recorder.cloudHistoryError.contains("Synthetic history download failure"),
              "A genuine history failure must remain visible instead of being treated as cancellation")
        NarwalService.cloudHistoryFailure = nil
        check(NarwalService.commands.isEmpty, "History sync and cancellation must remain read-only")
        print("Cloud sync cancellation checks passed: queued, in-flight, and caller cancellation wait for cleanup, finish quietly, preserve cached paths, send no robot commands, and leave genuine failures visible.")
        try await runLiveStoreChecks()
        try await runScheduleStoreChecks()
        try await runSessionStoreChecks()
        try await runCurrentTaskStoreChecks()
        try await runRoomNamesStoreChecks()
        try await runRoomMergeStoreChecks()
    }
}
