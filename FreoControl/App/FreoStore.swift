import SwiftUI
import AppIntents

@MainActor final class FreoStore: ObservableObject {
    #if os(iOS)
    static let shared = FreoStore(floorplanCache: FloorplanCache(), siriCatalog: SiriRoomCatalog())
    #else
    static let shared = FreoStore(floorplanCache: FloorplanCache())
    #endif
    @Published var selectedTab = 1
    @Published var isDemo = false
    @Published var isBusy = false
    @Published var devices: [RobotDevice] = []
    @Published var selectedDeviceID: String?
    @Published var status: RobotStatus?
    @Published var rooms: [RobotRoom] = []
    @Published var selectedRoomIDs: Set<Int> = []
    @Published var mode: CleaningMode = .vacuumMop
    @Published var cleaningOptions: CleaningOptions = .standard
    @Published var floorplan: Floorplan?
    @Published private(set) var isFloorplanCached = false
    @Published private(set) var trajectory: RobotTrajectory?
    @Published private(set) var trajectoryError = ""
    @Published private(set) var liveMapState: LiveMapConnectionState = .inactive
    @Published private(set) var liveMapMessage = "Open the map to receive robot updates."
    @Published private(set) var lastLiveMapAt: Date?
    @Published var scheduleSnapshot: ScheduleSnapshot?
    @Published var scheduleError = ""
    @Published var isSchedulesLoading = false
    var scheduleContext: ScheduleContextSnapshot?
    var scheduleWriteUncertain = false
    var scheduleScope = UUID()
    @Published private(set) var cleaningHistory: [CleaningRun] = []
    @Published private(set) var historyError = ""
    @Published private(set) var isHistoryLoading = false
    @Published private(set) var cloudCleaningRecords: [CloudCleaningRecord] = []
    @Published private(set) var isCloudHistoryLoading = false
    @Published private(set) var isCloudHistoryCancelling = false
    @Published private(set) var cloudHistoryError = ""
    @Published private(set) var hasMoreCloudHistory = true
    @Published var message = ""
    @Published var isAuthenticated = false
    @Published var rememberSession = true
    @Published private(set) var canRetrySavedSignIn = false
    @Published private(set) var savedSessionRemovalPending = false
    @Published var networkExpires: Date? = ISO8601DateFormatter().date(from: "2026-11-03T09:55:38Z")
    @Published var lastPlan: CleaningTaskSnapshot?
    @Published private(set) var currentTask: CurrentCleaningTask?
    @Published private(set) var currentTaskUpdatedAt: Date?
    @Published private(set) var currentTaskError = ""
    @Published private(set) var isCurrentTaskLoading = false
    @Published private(set) var supportsSweepIntensity: Bool?
    @Published private(set) var roomEditProgress = ""
    @Published private(set) var sessionExpiry: Date?
    var mapID: Int?
    var mapRevision: UInt32?
    private var roomsLoadedAt: Date?
    private var roomEditSnapshot: MapSnapshot?
    private var roomEditGeneration = UUID()
    let service = NarwalService()
    private let historyStore: CleaningHistoryStore
    private let floorplanCache: FloorplanCache?
    private let siriCatalog: SiriRoomCatalog?
    private let currentTaskNow: () -> Date
    private var currentTaskScope: TaskScope?
    private var currentTaskGeneration = UUID()
    private var lastCurrentTaskAttemptAt: Date?
    private struct TaskScope: Equatable {
        let productKey: String; let deviceID: String; let mapID: Int; let revision: UInt32?
    }
    private var observationWindowID = UUID()
    private var lastObservationAt: Date?
    private var cloudHistoryPage = 0
    private var cloudHistoryTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var backgroundReadInFlight = false
    private var backgroundReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var demoTask: Task<Void, Never>?
    private var foreground = true
    private var roomEditorActive = false
    private var mapVisible = false
    private var liveMapTask: Task<Void, Never>?
    private var liveMapShutdown: Task<Void, Never>?
    private var liveShutdownGeneration = UUID()
    private var liveMapPreparing = false
    private var liveFreshnessTask: Task<Void, Never>?
    private var liveGeneration = UUID()
    private var liveMapBaseline: LiveMapSnapshot?
    private var liveResyncRequested = false
    private var lastLivePersistedAt: Date?
    private var savedLive: SavedState?
    private var attemptedSessionRestore = false
    private var sessionRestoreTask: Task<Void, Never>?
    init(historyStore: CleaningHistoryStore = CleaningHistoryStore(), currentTaskNow: @escaping () -> Date = Date.init, floorplanCache: FloorplanCache? = nil, siriCatalog: SiriRoomCatalog? = nil) {
        self.historyStore = historyStore
        self.floorplanCache = floorplanCache
        self.siriCatalog = siriCatalog
        self.currentTaskNow = currentTaskNow
    }
    private struct SavedState {
        let devices: [RobotDevice]; let selectedID: String?; let status: RobotStatus?
        let rooms: [RobotRoom]; let selected: Set<Int>; let mode: CleaningMode
        let cleaningOptions: CleaningOptions
        let floorplan: Floorplan?; let plan: CleaningTaskSnapshot?; let cached: Bool
        let trajectory: RobotTrajectory?
        let mapID: Int?; let mapRevision: UInt32?; let loadedAt: Date?; let authenticated: Bool; let expiry: Date?
        let rememberSession: Bool
    }
    var selectedDevice: RobotDevice? { devices.first { $0.id == selectedDeviceID } }
    private var selectedTaskScope: TaskScope? {
        guard let robot = selectedDevice, let mapID else { return nil }
        return TaskScope(productKey: robot.productKey, deviceID: robot.id, mapID: mapID, revision: mapRevision)
    }
    var currentTaskIsFresh: Bool {
        guard !isDemo, isAuthenticated, currentTask != nil, currentTaskError.isEmpty,
              sessionExpiry.map({ $0 > currentTaskNow() }) == true,
              currentTaskScope == selectedTaskScope, currentTaskScope != nil,
              let updated = currentTaskUpdatedAt, let status,
              (0...45).contains(currentTaskNow().timeIntervalSince(status.updatedAt)),
              !(status.workingCode == 1 && status.isPaused != true) else { return false }
        return (0...45).contains(currentTaskNow().timeIntervalSince(updated))
    }
    var currentTaskRoomIDs: Set<Int> { currentTaskIsFresh ? Set(currentTask?.rooms.map(\.id) ?? []) : [] }
    var currentPositionRoom: RobotRoom? {
        guard !isDemo, isAuthenticated, let robot = selectedDevice, let floorplan, let trajectory,
              sessionExpiry.map({ $0 > currentTaskNow() }) == true,
              trajectory.deviceID == robot.id, trajectory.productKey == robot.productKey,
              floorplan.mapID == mapID, floorplan.mapRevision == mapRevision else { return nil }
        return CurrentCleaningTask.positionRoom(floorplan: floorplan, trajectory: trajectory, now: currentTaskNow())
    }
    var robotActivityTitle: String {
        if isDemo { return status?.label ?? "Demo" }
        guard isAuthenticated else { return "Not connected" }
        guard sessionExpiry.map({ $0 > currentTaskNow() }) == true,
              let status, (0...45).contains(currentTaskNow().timeIntervalSince(status.updatedAt)) else { return "Status unavailable" }
        if status.isPaused == true { return "Paused" }
        if status.workingCode == 1 { return "Standby" }
        if status.workingCode == 5, selectedDevice?.productKey == "EHf6cRNRGT",
           currentTaskIsFresh, currentTask?.rooms.isEmpty == false { return "Cleaning task" }
        return status.workingCode == nil ? "Status unavailable" : "Connected"
    }
    var canStart: Bool {
        !isBusy && !selectedRoomIDs.isEmpty && !rooms.isEmpty && (isDemo ? [1,10,14].contains(status?.workingCode ?? 10) : isAuthenticated && selectedDevice?.canControl == true && (mapID ?? 0) > 0 && (!isFloorplanCached || mapRevision != nil) && (roomsLoadedAt?.timeIntervalSinceNow ?? -1000) > -900)
    }
    func foregroundChanged(_ active: Bool) {
        foreground = active; pollTask?.cancel(); pollTask = nil
        stopLiveMap()
        resetObservationWindow()
        guard active else { return }
        reconcileLiveMap()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if !self.isDemo && self.isAuthenticated && !self.isBusy && !self.roomEditorActive {
                    await self.refreshStatus(quiet: true)
                }
            }
        }
    }
    func roomEditorPresented(_ presented: Bool) {
        if roomEditorActive != presented {
            roomEditGeneration = UUID()
            roomEditSnapshot = nil
        }
        roomEditorActive = presented
        if presented { stopLiveMap() } else { reconcileLiveMap() }
        resetObservationWindow()
    }
    func setMapVisible(_ visible: Bool) {
        guard mapVisible != visible else { return }
        mapVisible = visible
        if visible { reconcileLiveMap() } else { stopLiveMap() }
    }
    private var liveMapEligible: Bool {
        foreground && mapVisible && !roomEditorActive && !isDemo && isAuthenticated &&
            selectedDevice?.canControl == true && (sessionExpiry.map { $0 > Date() } ?? false)
    }
    private func stopLiveMap() {
        liveGeneration = UUID()
        if let active = liveMapTask {
            active.cancel()
            let previous = liveMapShutdown
            liveShutdownGeneration = UUID()
            liveMapShutdown = Task { await previous?.value; await active.value }
        }
        liveMapTask = nil; liveMapPreparing = false
        liveFreshnessTask?.cancel(); liveFreshnessTask = nil
        liveMapBaseline = nil; lastLiveMapAt = nil; lastLivePersistedAt = nil
        liveMapState = .inactive
        liveMapMessage = "Live reporting pauses when the map is closed or the app is in the background."
    }
    private func awaitStoppedLiveMap() async {
        let generation = liveShutdownGeneration, pending = liveMapShutdown
        await pending?.value
        if generation == liveShutdownGeneration { liveMapShutdown = nil }
    }
    func awaitLiveRequestSlot(waitForBackground: Bool = true) async {
        if waitForBackground, backgroundReadInFlight {
            await withCheckedContinuation { backgroundReadWaiters.append($0) }
        }
        // observeLiveWindow briefly owns the service lock while it obtains a
        // token/destination. Cancellation must unwind that phase before a read.
        if liveMapPreparing { stopLiveMap() }
        await awaitStoppedLiveMap()
    }
    private func reconcileLiveMap() {
        guard !isBusy, !backgroundReadInFlight, liveMapEligible, liveMapTask == nil else { return }
        let generation = UUID(); liveGeneration = generation
        // Capture the preceding shutdown before creating this task. A rapid
        // close/reopen can otherwise make a cancelled task await its own tail.
        let previousShutdown = liveMapShutdown
        liveMapTask = Task { [weak self] in
            await previousShutdown?.value
            guard !Task.isCancelled else { return }
            await self?.runLiveMap(generation: generation)
        }
        liveFreshnessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.liveGeneration == generation, self.liveMapEligible else { return }
                if self.liveMapState == .live, let received = self.lastLiveMapAt,
                   Date().timeIntervalSince(received) > 8 {
                    self.liveMapState = .waiting
                    self.liveMapMessage = "Waiting for robot updates. The last received path is still shown."
                }
            }
        }
    }
    private func runLiveMap(generation: UUID) async {
        var consecutiveResyncs = 0
        defer {
            if liveGeneration == generation {
                liveMapPreparing = false
                liveMapTask = nil; liveFreshnessTask?.cancel(); liveFreshnessTask = nil
                if !liveMapEligible { liveMapState = .inactive }
            }
        }
        while !Task.isCancelled, liveGeneration == generation, liveMapEligible {
            guard !isBusy, !backgroundReadInFlight, let robot = selectedDevice else {
                try? await Task.sleep(nanoseconds: 500_000_000); continue
            }
            liveMapState = .connecting; liveMapMessage = "Connecting to robot map updates…"
            liveResyncRequested = false
            do {
                let baseline: LiveMapSnapshot
                if let cached = liveMapBaseline, cached.snapshot.matches(device: robot, mapID: cached.snapshot.mapID),
                   abs(cached.snapshot.capturedAt.timeIntervalSinceNow) < 5 {
                    baseline = cached
                } else {
                    // Refresh geometry silently. User controls remain visually
                    // available, and a deliberate request waits for this read.
                    backgroundReadInFlight = true
                    do {
                        let result = try await service.liveMapSnapshot(device: robot)
                        try Task.checkCancellation()
                        guard liveGeneration == generation, liveMapEligible, selectedDeviceID == robot.id else { throw CancellationError() }
                        await applyLiveFloorplan(result, robot: robot)
                        baseline = result
                        finishBackgroundRead()
                    } catch { finishBackgroundRead(); throw error }
                }
                if isBusy { continue }
                liveMapBaseline = nil // each renewal requires a fresh map
                try Task.checkCancellation()
                guard liveGeneration == generation, liveMapEligible, selectedDeviceID == robot.id else { return }
                liveMapState = .waiting; liveMapMessage = "Waiting for the robot to accept live reporting…"
                liveMapPreparing = true
                let previousPush = lastLiveMapAt
                try await service.observeLiveWindow(device: robot, baseline: baseline) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.receiveLive(event, baseline: baseline, robot: robot, generation: generation)
                }
                guard liveGeneration == generation, liveMapEligible else { return }
                liveMapPreparing = false
                if lastLiveMapAt != previousPush { consecutiveResyncs = 0 }
                if liveResyncRequested {
                    consecutiveResyncs += 1
                    liveMapState = .polling
                    liveMapMessage = "Refreshing map continuity. Showing received updates only."
                    let delay: UInt64 = consecutiveResyncs == 1 ? 1 : consecutiveResyncs == 2 ? 5 : 15
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                } else if lastLiveMapAt == previousPush {
                    liveMapState = .polling
                    liveMapMessage = "The robot sent no live map updates. Refreshing by periodic reads."
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
            } catch {
                guard !Task.isCancelled, liveGeneration == generation, liveMapEligible else { return }
                liveMapPreparing = false
                if await service.sessionExpiration() == nil { clearPresentation(); return }
                liveMapState = .polling
                liveMapMessage = "Live reporting is unavailable. Refreshing by periodic reads. \(error.localizedDescription)"
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
    private func receiveLive(_ event: LiveTelemetryEvent, baseline: LiveMapSnapshot,
                             robot: RobotDevice, generation: UUID) async throws {
        try Task.checkCancellation()
        guard liveGeneration == generation, liveMapEligible, selectedDeviceID == robot.id,
              mapID == baseline.snapshot.mapID, mapRevision == baseline.snapshot.editVersion else { throw CancellationError() }
        switch event {
        case .activated:
            liveMapPreparing = false
            liveMapState = .waiting
            liveMapMessage = "Robot reporting enabled. Waiting for its first map update."
        case .resyncRequired(let reason):
            liveResyncRequested = true; liveMapState = .polling; liveMapMessage = reason
        case .trajectory(let received):
            guard received.productKey == robot.productKey, received.deviceID == robot.id,
                  received.mapID == mapID, received.mapVersion == baseline.snapshot.mapVersion,
                  received.editVersion == mapRevision, !received.isSimulated else {
                throw ConnectorError.invalid("The robot update does not match the displayed map.")
            }
            trajectory = received; lastLiveMapAt = received.capturedAt; lastObservationAt = received.capturedAt
            trajectoryError = Self.routeFreshnessWarning(received, maximumAge: 8)
            if trajectoryError.isEmpty && received.pose != nil {
                liveMapState = .live
                liveMapMessage = "Receiving robot map updates; a two-second reporting interval was requested."
            } else {
                liveMapState = .waiting
                liveMapMessage = "Map updates are arriving. Waiting for a fresh robot position; the last received path is shown."
            }
            guard lastLivePersistedAt.map({ received.capturedAt.timeIntervalSince($0) >= 15 }) ?? true,
                  let status, status.workingCode != nil, status.workingCode != 1,
                  abs(status.updatedAt.timeIntervalSince(received.capturedAt)) <= 60 else { return }
            lastLivePersistedAt = received.capturedAt
            do {
                let records = try await historyStore.observeLive(snapshot: baseline.snapshot,
                    trajectory: received, windowID: observationWindowID,
                    modeName: historyTaskContext(at: received.capturedAt).mode,
                    roomNames: historyTaskContext(at: received.capturedAt).rooms)
                guard liveGeneration == generation, liveMapEligible else { return }
                cleaningHistory = records; historyError = ""
            } catch { historyError = "This received path could not be saved on this device. \(error.localizedDescription)" }
        }
    }
    func signIn(email: String, password: String) async {
        guard !isDemo else { return }
        let remember = true
        await perform {
            do {
                let found = try await self.service.signIn(email: email, password: password, rememberSession: remember)
                await self.presentConnectedAccount(found)
            } catch {
                guard await self.service.sessionExpiration() != nil else { throw error }
                if let found = try await self.service.restoreSession() {
                    await self.presentConnectedAccount(found)
                }
                self.message = error.localizedDescription
            }
        }
        reconcileLiveMap()
    }
    /// One startup attempt shared with Siri; restoration only reads the account.
    func restoreSavedSessionIfNeeded(retry: Bool = false) async {
        if let pending = sessionRestoreTask { await pending.value; return }
        guard (!attemptedSessionRestore || retry && canRetrySavedSignIn), !isDemo, !isAuthenticated, !isBusy else { return }
        attemptedSessionRestore = true
        let pending = Task<Void, Never> { [weak self] in await self?.restoreSavedSession() }
        sessionRestoreTask = pending
        await pending.value
        sessionRestoreTask = nil
    }
    func restoreSavedSession() async {
        guard !isDemo, !isAuthenticated else { return }
        await perform {
            do {
                guard let found = try await self.service.restoreSession() else {
                    self.canRetrySavedSignIn = false
                    return
                }
                await self.presentConnectedAccount(found)
            } catch {
                self.canRetrySavedSignIn = true
                self.networkExpires = await self.service.networkExpiration()
                throw error
            }
        }
        reconcileLiveMap()
    }
    func setRememberSession(_ enabled: Bool) async {
        guard !isDemo, isAuthenticated else { return }
        await perform {
            do { try await self.service.setSessionRemembered(enabled) }
            catch {
                self.rememberSession = await self.service.isSessionRemembered()
                if !enabled { self.savedSessionRemovalPending = true }
                throw error
            }
            self.rememberSession = await self.service.isSessionRemembered()
            self.savedSessionRemovalPending = false
            self.message = ""
        }
    }
    func removeSavedSignIn() async {
        guard !isDemo else { return }
        await perform {
            try await self.service.setSessionRemembered(false)
            self.rememberSession = false; self.savedSessionRemovalPending = false
            self.canRetrySavedSignIn = false; self.message = ""
        }
    }
    private func presentConnectedAccount(_ found: [RobotDevice]) async {
        let expiry = await service.sessionExpiration()
        let remembered = await service.isSessionRemembered()
        let cachedRooms = try? siriCatalog?.load()
        let preserveRooms = found.first.map { robot in
            guard let cachedRooms, !cachedRooms.isEmpty else { return false }
            return cachedRooms.allSatisfy { $0.deviceID == robot.id && $0.productKey == robot.productKey }
        } ?? false
        clearPresentation(preserveSiriCatalog: preserveRooms); devices = found; isAuthenticated = true
        rememberSession = remembered; canRetrySavedSignIn = false
        savedSessionRemovalPending = false
        sessionExpiry = expiry; networkExpires = await service.networkExpiration()
        selectedDeviceID = found.first?.id
        message = found.isEmpty ? "Signed in, but no usable robot was found." : ""
        if let robot = selectedDevice {
            await restoreCachedFloorplan(for: robot)
            do { status = try await service.status(device: robot) }
            catch {
                rememberSession = await service.isSessionRemembered()
                if await service.sessionExpiration() == nil {
                    clearPresentation()
                    message = error.localizedDescription
                } else { message = "Signed in. Status could not be read: " + error.localizedDescription }
            }
        }
        if isAuthenticated { publishSiriRooms() }
    }
    func refreshStatus() async { await refreshStatus(quiet: false) }
    func refreshStatus(quiet: Bool) async {
        guard !isDemo, let robot = selectedDevice, isAuthenticated else { return }
        if !quiet { stopLiveMap() }
        defer { reconcileLiveMap() }
        await perform(quiet: quiet) {
            let previousCode = self.status?.workingCode
            do {
                let received = try await self.service.status(device: robot)
                try Task.checkCancellation()
                guard self.isAuthenticated, !self.isDemo, self.selectedDevice == robot else { throw CancellationError() }
                self.status = received
            }
            catch {
                guard self.isAuthenticated, !self.isDemo, self.selectedDevice == robot else { throw CancellationError() }
                self.currentTaskError = "Current task is stale because robot status could not be refreshed."
                self.trajectoryError = "Robot refresh unavailable. The last received route is still shown."
                self.resetObservationWindow()
                throw error
            }
            // A user command queued during the status read gets the next slot.
            if quiet && self.isBusy { return }
            if previousCode != 1 && self.status?.workingCode == 1 { self.resetObservationWindow() }
            if self.status?.workingCode == 1 && self.status?.isPaused != true {
                self.invalidateCurrentTask()
            } else if self.shouldAutoReadCurrentTask {
                // Current task is read at most once per30 seconds during the
                // existing foreground poll. Capability diagnostics stay manual.
                do { try await self.readCurrentTask(robot: robot, background: quiet) }
                catch { /* The task-specific error keeps the previous read stale. */ }
            }
            try Task.checkCancellation()
            guard self.isAuthenticated, !self.isDemo, self.selectedDevice == robot else { throw CancellationError() }
            if quiet && self.isBusy { return }
            if !quiet { self.message = "" }
            if !quiet || (self.mapVisible && (self.liveMapState == .polling || self.liveMapTask == nil)) {
                do { try await self.readLiveFloorplan(robot: robot) }
                catch {
                    self.trajectoryError = "Path refresh unavailable. The last received route is still shown."
                    self.resetObservationWindow()
                    if await self.service.sessionExpiration() == nil { throw error }
                }
            }
        }
    }
    func loadRooms() async {
        guard !isDemo, let robot = selectedDevice else { return }
        await perform {
            let result = try await self.service.loadRooms(device: robot)
            self.applyRoomMap(result)
            self.message = result.rooms.isEmpty ? "No saved rooms were returned." : ""
        }
    }
    func loadFloorplan() async {
        guard !isDemo, let robot = selectedDevice else { return }
        stopLiveMap()
        defer { reconcileLiveMap() }
        await perform {
            do { try await self.readLiveFloorplan(robot: robot) }
            catch {
                self.trajectoryError = "Path refresh unavailable. The last received route is still shown."
                self.resetObservationWindow()
                throw error
            }
            self.message = ""
        }
    }
    private func readLiveFloorplan(robot: RobotDevice) async throws {
        let result = try await service.liveMapSnapshot(device: robot)
        try Task.checkCancellation()
        guard selectedDeviceID == robot.id, isAuthenticated, !isDemo else { throw CancellationError() }
        liveMapBaseline = result
        await applyLiveFloorplan(result, robot: robot)
    }
    private static func routeFreshnessWarning(_ received: RobotTrajectory, maximumAge: TimeInterval = 90) -> String {
        guard let milliseconds = received.deviceTimestampMilliseconds else {
            return "The robot did not provide a position timestamp. Position freshness is unknown."
        }
        if abs(Double(milliseconds) / 1000 - received.capturedAt.timeIntervalSince1970) > maximumAge {
            return "The robot returned an older position. Its freshness is not confirmed."
        }
        return ""
    }
    private func applyLiveFloorplan(_ result: LiveMapSnapshot, robot: RobotDevice) async {
        guard selectedDeviceID == robot.id, isAuthenticated, !isDemo else { return }
        let snapshot = result.snapshot
        if let lastObservationAt, snapshot.capturedAt.timeIntervalSince(lastObservationAt) > 90 {
            resetObservationWindow()
        }
        applyRoomMap(RoomMap(mapID: snapshot.mapID, rooms: snapshot.floorplan.rooms,
                             mapRevision: snapshot.editVersion), footprint: snapshot.floorplan)
        floorplan = snapshot.floorplan; isFloorplanCached = false; trajectory = result.trajectory
        try? await floorplanCache?.save(floorplan: snapshot.floorplan, device: robot)
        guard selectedDevice == robot, isAuthenticated, !isDemo,
              mapID == snapshot.mapID, mapRevision == snapshot.editVersion else { return }
        trajectoryError = Self.routeFreshnessWarning(result.trajectory)
        lastObservationAt = snapshot.capturedAt
        // Standby can return a previous route while the station resets it.
        // Keep that telemetry visible, but don't create a new idle recording.
        guard let status, status.workingCode != nil, status.workingCode != 1,
              abs(status.updatedAt.timeIntervalSince(snapshot.capturedAt)) <= 60 else { return }
        // Record the robot's fresh task context with the route. Picker values
        // and accepted commands never substitute for a reported task.
        do {
            let records = try await historyStore.observe(snapshot: snapshot,
                trajectory: result.trajectory, windowID: observationWindowID,
                modeName: historyTaskContext(at: result.trajectory.capturedAt).mode,
                roomNames: historyTaskContext(at: result.trajectory.capturedAt).rooms)
            guard selectedDeviceID == robot.id, isAuthenticated, !isDemo else { return }
            cleaningHistory = records
            historyError = ""
        } catch {
            historyError = "This path could not be saved on this device. \(error.localizedDescription)"
        }
    }
    /// Target labels from a fresh task response for this robot/map, not rooms
    /// crossed by a path or the controls currently selected by the user.
    private func historyTaskContext(at capturedAt: Date) -> (mode: String?, rooms: [String]) {
        guard currentTaskIsFresh, let task = currentTask, let readAt = currentTaskUpdatedAt,
              abs(capturedAt.timeIntervalSince(readAt)) <= 45 else { return (nil, []) }
        let modes = task.modeNames.filter { !$0.hasPrefix("Unknown mode") }
        return (modes.isEmpty ? nil : modes.joined(separator: " / "), task.rooms.map(\.name))
    }
    func loadCleaningHistory() async {
        guard !isHistoryLoading else { return }
        isHistoryLoading = true; defer { isHistoryLoading = false }
        do { cleaningHistory = try await historyStore.load(); historyError = "" }
        catch { historyError = "Saved paths could not be opened. \(error.localizedDescription)" }
    }
    func deleteCleaningRun(id: UUID) async {
        do { cleaningHistory = try await historyStore.delete(id: id); historyError = "" }
        catch { historyError = "This saved path could not be deleted. \(error.localizedDescription)" }
    }
    func loadCloudHistory(loadMore: Bool = false) async {
        guard isAuthenticated, !isDemo, let robot = selectedDevice else {
            cloudHistoryError = "Connect your robot to read its Narwal cleaning records."
            return
        }
        guard !isBusy, !isCloudHistoryLoading else {
            cloudHistoryError = "Wait for the current request to finish, then try again."
            return
        }
        guard !loadMore || hasMoreCloudHistory else { return }
        let page = loadMore ? cloudHistoryPage + 1 : 1
        isBusy = true; isCloudHistoryLoading = true; isCloudHistoryCancelling = false
        // Keep the service lock until cancellation has unwound the in-flight
        // request. Releasing it immediately could race a Pause/Dock request
        // with a still-busy service and silently discard that user action.
        defer {
            cloudHistoryTask = nil
            isBusy = false; isCloudHistoryLoading = false; isCloudHistoryCancelling = false
        }
        let task = Task { [self] in
            // Own the cancellable task before waiting for another read. A tap
            // on Cancel during that wait must prevent the history request too.
            await awaitLiveRequestSlot()
            await syncCloudHistory(robot: robot, page: page, loadMore: loadMore)
        }
        cloudHistoryTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
    func cancelCloudHistorySync() {
        guard isCloudHistoryLoading, let task = cloudHistoryTask else { return }
        isCloudHistoryCancelling = true
        task.cancel()
    }
    private func syncCloudHistory(robot: RobotDevice, page: Int, loadMore: Bool) async {
        do {
            try Task.checkCancellation()
            let records = try await service.history(device: robot, page: page)
            try Task.checkCancellation()
            guard selectedDeviceID == robot.id, isAuthenticated, !isDemo else { return }
            let old = loadMore ? cloudCleaningRecords : []
            let oldIDs = Set(old.map(\.id))
            cloudCleaningRecords = old + records.filter { !oldIDs.contains($0.id) }
            cloudHistoryPage = page
            // The endpoint has no total/cursor. An empty or repeating page is
            // the only observed stopping signal; page one is not "all history".
            hasMoreCloudHistory = page < 100 && records.contains { !oldIDs.contains($0.id) }
            cloudHistoryError = ""
            // Save each returned route for offline viewing. This bounded page
            // sync only reads Narwal HTTPS records; it never starts a clean.
            var unavailable = 0
            for record in records {
                try Task.checkCancellation()
                let cached = cleaningHistory.contains {
                    $0.cloudRecordID == record.id && $0.trajectory.deviceID == robot.id &&
                    $0.trajectory.productKey == robot.productKey && record.endedAt != nil &&
                    $0.updatedAt == record.endedAt
                }
                if cached { continue }
                do {
                    let run = try await service.historicalRoute(device: robot, record: record)
                    try Task.checkCancellation()
                    cleaningHistory = try await historyStore.importCloud(run: run)
                    try Task.checkCancellation()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    unavailable += 1
                    if await service.sessionExpiration() == nil { throw error }
                }
            }
            if unavailable > 0 {
                cloudHistoryError = "\(unavailable) recorded paths could not be saved. Open a record to try again."
            }
        } catch {
            cloudHistoryError = Task.isCancelled ? "" : error.localizedDescription
            if await service.sessionExpiration() == nil { clearPresentation() }
        }
    }
    func openCloudCleaningRecord(_ record: CloudCleaningRecord) async -> CleaningRun? {
        if let saved = cleaningHistory.first(where: {
            $0.cloudRecordID == record.id && $0.trajectory.deviceID == record.deviceID &&
            $0.trajectory.productKey == record.productKey && record.endedAt != nil &&
            $0.updatedAt == record.endedAt
        }) { return saved }
        guard isAuthenticated, !isDemo, let robot = selectedDevice else {
            cloudHistoryError = "Connect your robot to download this recorded path."
            return nil
        }
        guard !isBusy else {
            cloudHistoryError = "Wait for the current request to finish, then try again."
            return nil
        }
        isBusy = true; defer { isBusy = false }
        await awaitLiveRequestSlot()
        do {
            let run = try await service.historicalRoute(device: robot, record: record)
            do { cleaningHistory = try await historyStore.importCloud(run: run); historyError = "" }
            catch { historyError = "The route was downloaded but could not be kept on this device. \(error.localizedDescription)" }
            cloudHistoryError = ""
            return run
        } catch {
            cloudHistoryError = error.localizedDescription
            if await service.sessionExpiration() == nil { clearPresentation() }
            return nil
        }
    }
    private func resetObservationWindow() {
        observationWindowID = UUID(); lastObservationAt = nil
    }
    func prepareRoomEditing() async throws -> Floorplan {
        guard !isBusy else { throw ConnectorError.invalid("Wait for the current request to finish.") }
        stopLiveMap()
        roomEditSnapshot = nil; roomEditProgress = ""
        if isDemo {
            guard let floorplan else { throw ConnectorError.invalid("Load the demo floorplan first.") }
            return floorplan
        }
        guard isAuthenticated, let robot = selectedDevice, robot.canControl,
              let mapID, mapID > 0 else { throw ConnectorError.invalid("Connect your Freo X Ultra and load its floorplan first.") }
        let scope = roomEditGeneration
        isBusy = true; defer { isBusy = false }
        await awaitLiveRequestSlot()
        try requireRoomEditingScope(robot: robot, mapID: mapID, generation: scope)
        let snapshot = try await service.editableMapSnapshot(device: robot, mapID: mapID)
        try requireRoomEditingScope(robot: robot, mapID: mapID, generation: scope)
        guard snapshot.matches(device: robot, mapID: mapID) else { throw MapEditError.staleSnapshot }
        // Establish the coordinate convention before presenting a writable map.
        _ = try MapEditCoordinates(snapshot: snapshot)
        roomEditSnapshot = snapshot
        applyRoomMap(RoomMap(mapID: snapshot.mapID, rooms: snapshot.floorplan.rooms, mapRevision: snapshot.editVersion), footprint: snapshot.floorplan)
        floorplan = snapshot.floorplan; isFloorplanCached = false
        try? await floorplanCache?.save(floorplan: snapshot.floorplan, device: robot)
        try requireRoomEditingScope(robot: robot, mapID: mapID, generation: scope)
        return snapshot.floorplan
    }
    /// Renaming does not need a partition proposal and never sends geometry edits.
    func saveRoomNames(_ names: [Int: String], baseline reviewed: Floorplan) async throws {
        guard !isBusy else { throw ConnectorError.invalid("Wait for the current request to finish.") }
        let changed = try RoomRenameTransaction.changedNames(in: reviewed, requested: names)
        guard !changed.isEmpty else { return }
        try Task.checkCancellation()
        if isDemo {
            guard floorplan == reviewed else { throw MapEditError.staleSnapshot }
            let renamed = Floorplan(mapID: reviewed.mapID, width: reviewed.width, height: reviewed.height,
                resolution: reviewed.resolution, rooms: reviewed.rooms.map { RobotRoom(id: $0.id, name: changed[$0.id] ?? $0.name) },
                pixels: reviewed.pixels, mapRevision: reviewed.mapRevision)
            applyEditedMap(renamed)
            message = "Room names saved."
            return
        }
        guard isAuthenticated, let robot = selectedDevice, robot.canControl,
              let baseline = roomEditSnapshot, baseline.matches(device: robot, mapID: reviewed.mapID),
              baseline.floorplan == reviewed, mapRevision == baseline.editVersion else {
            throw ConnectorError.invalid("Reload the room names before saving.")
        }
        let scope = roomEditGeneration
        roomEditSnapshot = nil
        isBusy = true; defer { isBusy = false; roomEditProgress = "" }
        await awaitLiveRequestSlot()
        do {
            try requireRoomEditingScope(robot: robot, mapID: baseline.mapID, generation: scope)
            let currentStatus = try await service.status(device: robot)
            try requireRoomEditingScope(robot: robot, mapID: baseline.mapID, generation: scope)
            status = currentStatus
            try requireRoomNamingStandby(currentStatus)
            roomEditProgress = "Saving names…"
            let result = try await RoomRenameTransaction.commit(baseline: baseline, names: changed,
                read: { [self] in
                    try await self.readRoomNamesSnapshot(robot: robot, mapID: baseline.mapID, generation: scope)
                }, apply: { [self] fresh, operations in
                    try await self.applyRoomNames(robot: robot, generation: scope, snapshot: fresh, operations: operations)
                }, preserveReadback: { _ in /* NarwalService preserves the exact backup and readback. */ })
            try requireRoomEditingScope(robot: robot, mapID: baseline.mapID, generation: scope)
            applyEditedMap(result.floorplan)
            try? await floorplanCache?.save(floorplan: result.floorplan, device: robot)
            try requireRoomEditingScope(robot: robot, mapID: baseline.mapID, generation: scope)
            message = "Room names saved."
        } catch {
            // Recover the presentation with a read only; keep the writable
            // baseline invalid even when this recovery succeeds.
            if roomEditingScopeMatches(robot: robot, mapID: baseline.mapID, generation: scope) {
                if let current = try? await service.editableMapSnapshot(device: robot, mapID: baseline.mapID),
                   roomEditingScopeMatches(robot: robot, mapID: baseline.mapID, generation: scope),
                   current.matches(device: robot, mapID: baseline.mapID) {
                    applyEditedMap(current.floorplan)
                }
                if roomEditingScopeMatches(robot: robot, mapID: baseline.mapID, generation: scope) {
                    message = error.localizedDescription
                }
            }
            throw error
        }
    }
    private func roomEditingScopeMatches(robot: RobotDevice, mapID: Int, generation: UUID) -> Bool {
        roomEditGeneration == generation && roomEditorActive && !isDemo && isAuthenticated &&
            selectedDevice == robot && self.mapID == mapID
    }
    private func requireRoomEditingScope(robot: RobotDevice, mapID: Int, generation: UUID) throws {
        try Task.checkCancellation()
        guard roomEditingScopeMatches(robot: robot, mapID: mapID, generation: generation) else {
            throw ConnectorError.invalid("The room editor changed. Reopen it before saving.")
        }
    }
    private func requireRoomNamingStandby(_ current: RobotStatus) throws {
        guard current.workingCode == 1, current.isPaused != true else {
            throw ConnectorError.invalid("Wait until the robot is on standby before saving room names.")
        }
    }
    private func readRoomNamesSnapshot(robot: RobotDevice, mapID: Int, generation: UUID) async throws -> MapSnapshot {
        try requireRoomEditingScope(robot: robot, mapID: mapID, generation: generation)
        let snapshot = try await service.editableMapSnapshot(device: robot, mapID: mapID)
        try requireRoomEditingScope(robot: robot, mapID: mapID, generation: generation)
        return snapshot
    }
    private func applyRoomNames(robot: RobotDevice, generation: UUID, snapshot: MapSnapshot, operations: [RoomMapOperation]) async throws -> MapEditCommitResult {
        try requireRoomEditingScope(robot: robot, mapID: snapshot.mapID, generation: generation)
        let currentStatus = try await service.status(device: robot)
        try requireRoomEditingScope(robot: robot, mapID: snapshot.mapID, generation: generation)
        status = currentStatus
        try requireRoomNamingStandby(currentStatus)
        let result = try await service.applyRoomOperations(device: robot, baseline: snapshot, operations: operations)
        try requireRoomEditingScope(robot: robot, mapID: snapshot.mapID, generation: generation)
        return result
    }
    /// Merge exactly the two reviewed rooms. An uncertain result is never retried.
    func saveRoomMerge(_ sourceRoomIDs: Set<Int>, baseline reviewed: Floorplan) async throws {
        guard !isBusy else { throw ConnectorError.invalid("Wait for the current request to finish.") }
        try RoomMergeTransaction.validate(floorplan: reviewed, sourceRoomIDs: sourceRoomIDs)
        try Task.checkCancellation()
        if isDemo {
            guard floorplan == reviewed else { throw MapEditError.staleSnapshot }
            let merged = try RoomMergeTransaction.demoMergedFloorplan(floorplan: reviewed, sourceRoomIDs: sourceRoomIDs)
            applyEditedMap(merged)
            message = "Demo rooms merged."
            return
        }
        guard isAuthenticated, let robot = selectedDevice, robot.canControl,
              let baseline = roomEditSnapshot, baseline.matches(device: robot, mapID: reviewed.mapID),
              baseline.floorplan == reviewed, mapRevision == baseline.editVersion else {
            throw ConnectorError.invalid("Reload the editable map before merging rooms.")
        }
        let scope = roomEditGeneration
        roomEditSnapshot = nil
        isBusy = true; defer { isBusy = false; roomEditProgress = "" }
        await awaitLiveRequestSlot()
        do {
            try requireRoomEditingScope(robot: robot, mapID: baseline.mapID, generation: scope)
            let currentStatus = try await service.status(device: robot)
            try requireRoomEditingScope(robot: robot, mapID: baseline.mapID, generation: scope)
            status = currentStatus
            try requireRoomMergeStandby(currentStatus)
            roomEditProgress = "Merging rooms…"
            let result = try await RoomMergeTransaction.commit(baseline: baseline, sourceRoomIDs: sourceRoomIDs,
                read: { [self] in
                    try await self.readRoomNamesSnapshot(robot: robot, mapID: baseline.mapID, generation: scope)
                }, apply: { [self] fresh, operations in
                    try await self.applyRoomMerge(robot: robot, generation: scope, snapshot: fresh, operations: operations)
                }, preserveReadback: { _ in /* NarwalService preserves the exact backup and readback. */ })
            try requireRoomEditingScope(robot: robot, mapID: baseline.mapID, generation: scope)
            applyEditedMap(result.floorplan)
            try? await floorplanCache?.save(floorplan: result.floorplan, device: robot)
            try requireRoomEditingScope(robot: robot, mapID: baseline.mapID, generation: scope)
            message = "Rooms merged and verified on the robot’s map."
        } catch {
            // Only recover the display. A fresh editor review is required for
            // any later edit, even when this read discovers a completed merge.
            if roomEditingScopeMatches(robot: robot, mapID: baseline.mapID, generation: scope) {
                if let current = try? await service.editableMapSnapshot(device: robot, mapID: baseline.mapID),
                   roomEditingScopeMatches(robot: robot, mapID: baseline.mapID, generation: scope),
                   current.matches(device: robot, mapID: baseline.mapID) {
                    applyEditedMap(current.floorplan)
                }
                if roomEditingScopeMatches(robot: robot, mapID: baseline.mapID, generation: scope) {
                    message = error.localizedDescription
                }
            }
            throw error
        }
    }
    private func requireRoomMergeStandby(_ current: RobotStatus) throws {
        guard current.workingCode == 1, current.isPaused != true else {
            throw ConnectorError.invalid("Finish the current cleaning task and leave the robot on standby before merging rooms.")
        }
    }
    private func applyRoomMerge(robot: RobotDevice, generation: UUID, snapshot: MapSnapshot, operations: [RoomMapOperation]) async throws -> MapEditCommitResult {
        try requireRoomEditingScope(robot: robot, mapID: snapshot.mapID, generation: generation)
        let currentStatus = try await service.status(device: robot)
        try requireRoomEditingScope(robot: robot, mapID: snapshot.mapID, generation: generation)
        status = currentStatus
        try requireRoomMergeStandby(currentStatus)
        let result = try await service.applyRoomOperations(device: robot, baseline: snapshot, operations: operations)
        try requireRoomEditingScope(robot: robot, mapID: snapshot.mapID, generation: generation)
        return result
    }
    func saveRoomPartition(_ plan: RoomPartitionPlan, kitchenName: String, hallwayName: String, resumeOnly: Bool = false) async throws {
        guard !isBusy else { throw ConnectorError.invalid("Wait for the current request to finish.") }
        let kitchen = kitchenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hallway = hallwayName.trimmingCharacters(in: .whitespacesAndNewlines)
        try NarwalCodec.validateRoomName(kitchen)
        try NarwalCodec.validateRoomName(hallway)
        guard kitchen.compare(hallway, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else {
            throw ConnectorError.invalid("Use different names for the two rooms.")
        }
        if isDemo {
            guard let current = floorplan else { throw ConnectorError.invalid("Reload the demo map.") }
            try plan.validateBaseline(current)
            let next = (current.rooms.map(\.id).max() ?? 0) + 1
            guard next + 1 <= 255 else { throw ConnectorError.invalid("No room IDs are available.") }
            var pixels = current.pixels
            for cell in plan.kitchenCells { pixels[cell] = (pixels[cell] & ~0xff00) | UInt32(next << 8) }
            for cell in plan.hallwayCells { pixels[cell] = (pixels[cell] & ~0xff00) | UInt32((next + 1) << 8) }
            let rooms = current.rooms.filter { !plan.sourceRoomIDs.contains($0.id) }
                + [RobotRoom(id: next, name: kitchen), RobotRoom(id: next + 1, name: hallway)]
            let result = Floorplan(mapID: current.mapID, width: current.width, height: current.height,
                                   resolution: current.resolution, rooms: rooms, pixels: pixels)
            _ = try plan.validateFinalPartition(result)
            applyEditedMap(result); message = "Demo room boundaries updated."
            return
        }
        guard isAuthenticated, let robot = selectedDevice, let baseline = roomEditSnapshot,
              baseline.matches(device: robot, mapID: plan.mapID) else {
            throw ConnectorError.invalid("Reload the editable map before saving.")
        }
        roomEditSnapshot = nil // A failed or uncertain edit must start from a new read.
        let namingExistingRooms = (try? RoomPartitionTransaction.remainingStage(plan: plan, floorplan: baseline.floorplan)) == .finalPartitionSaved
        isBusy = true; defer { isBusy = false; roomEditProgress = "" }
        await awaitLiveRequestSlot()
        do {
            let currentStatus = try await service.status(device: robot)
            status = currentStatus
            guard currentStatus.workingCode == 1, currentStatus.isPaused != true else {
                throw ConnectorError.invalid("Finish the current cleaning task and leave the robot on standby before changing room boundaries.")
            }
            let result = try await RoomPartitionTransaction.commit(plan: plan, baseline: baseline,
                kitchenName: kitchen, hallwayName: hallway, resumeOnly: resumeOnly,
                read: { [service] in try await service.editableMapSnapshot(device: robot, mapID: plan.mapID) },
                apply: { [service] snapshot, operations in
                    let status = try await service.status(device: robot)
                    guard status.workingCode == 1, status.isPaused != true else {
                        throw ConnectorError.invalid("The robot left standby. Stop editing and review the map after its current task finishes.")
                    }
                    return try await service.applyRoomOperations(device: robot, baseline: snapshot, operations: operations)
                },
                progress: { [self] text in await self.updateRoomEditProgress(text) })
            applyEditedMap(result.floorplan)
            message = namingExistingRooms ? "Room names saved; existing boundaries preserved." : "Room boundaries saved and verified on the robot’s map."
        } catch {
            // Read only: recover presentation after a partial/uncertain save.
            if let current = try? await service.editableMapSnapshot(device: robot, mapID: plan.mapID) {
                applyEditedMap(current.floorplan)
            } else {
                floorplan = nil; rooms = []; selectedRoomIDs = []; roomsLoadedAt = nil
            }
            message = error.localizedDescription
            throw error
        }
    }
    private func updateRoomEditProgress(_ text: String) { roomEditProgress = text }
    private func applyEditedMap(_ map: Floorplan) {
        applyRoomMap(RoomMap(mapID: map.mapID, rooms: map.rooms, mapRevision: map.mapRevision), footprint: map)
        floorplan = map; isFloorplanCached = false; selectedRoomIDs = []; lastPlan = nil; trajectory = nil
        resetObservationWindow()
    }
    /// OS phrase expansion must not wait on account restoration or cloud I/O.
    func siriRoomSuggestions() async throws -> [SiriRoomReference] {
        try Task.checkCancellation()
        if let siriCatalog {
            guard !isDemo else { return [] }
            if let cached = try? siriCatalog.load(), !cached.isEmpty,
               selectedDevice == nil || cached.allSatisfy({ $0.deviceID == selectedDevice?.id && $0.productKey == selectedDevice?.productKey }) {
                return cached
            }
            if let robot = selectedDevice, let mapID, !rooms.isEmpty {
                return roomReferences(robot: robot, mapID: mapID, rooms: rooms, revision: mapRevision)
            }
            // OS indexing must never trigger authentication/cloud requests, or
            // recursively republish shortcuts during the lookup it initiated.
            return []
        }
        return try await siriRooms()
    }
    func resolveSiriRoom(identifier: String, current: [SiriRoomReference]) async throws -> SiriRoomReference? {
        if let direct = current.first(where: { $0.id == identifier }) { return direct }
        return try siriCatalog?.resolve(identifier: identifier, current: current)
    }
    private func publishSiriRooms() {
        guard !isDemo, let robot = selectedDevice, let mapID, !rooms.isEmpty else { return }
        let references = roomReferences(robot: robot, mapID: mapID, rooms: rooms, revision: mapRevision)
        if let siriCatalog {
            if (try? siriCatalog.isCurrent(references)) == true { return }
            do { try siriCatalog.save(references) } catch { return }
        }
        FreoSiriRoomIndex.refresh(references)
        FreoShortcuts.updateAppShortcutParameters()
    }
    /// Siri resolves current room entities, never a hardcoded list of room names.
    func siriRooms() async throws -> [SiriRoomReference] {
        try Task.checkCancellation()
        await restoreSavedSessionIfNeeded(retry: true)
        try requireSiriSession()
        // Room choices can use the last saved catalog. siriStart always reads
        // the robot's current map and validates these references before sending.
        if let mapID, !rooms.isEmpty, let robot = selectedDevice {
            return roomReferences(robot: robot, mapID: mapID, rooms: rooms, revision: mapRevision)
        }
        guard !isBusy, let robot = selectedDevice else { throw ConnectorError.invalid("Another request is running. Try Siri again when it finishes.") }
        isBusy = true; defer { isBusy = false; reconcileLiveMap() }
        do {
            await awaitLiveRequestSlot()
            try Task.checkCancellation()
            let map = try await service.loadRooms(device: robot)
            try Task.checkCancellation()
            try requireSiriSession()
            guard let mapID = map.mapID, mapID > 0, !map.rooms.isEmpty else { throw ConnectorError.invalid("This robot has no saved rooms to choose. Open Narwal and load its floorplan.") }
            applyRoomMap(map)
            return roomReferences(robot: robot, mapID: mapID, rooms: map.rooms, revision: map.mapRevision)
        } catch {
            message = error.localizedDescription
            rememberSession = await service.isSessionRemembered()
            if await service.sessionExpiration() == nil { clearPresentation(); selectedTab = 2 }
            throw error
        }
    }
    /// Voice and Shortcuts share the normal command path. Re-read the map before
    /// sending so a saved shortcut can never silently target a different room.
    func siriStart(mode requestedMode: CleaningMode, references: [SiriRoomReference]) async throws -> String {
        try Task.checkCancellation()
        #if DEBUG && FREO_SIRI_ROUTING_TESTS
        if FreoSiriRoutingTestMode.isActive {
            let catalog = try await siriRoomSuggestions()
            let selected = try SiriRoomReference.validate(requested: references, against: catalog)
            let names = catalog.filter { selected.contains($0.roomID) }.map(\.name)
            mode = requestedMode; selectedRoomIDs = Set(selected); selectedTab = 0
            message = FreoSiriRoutingTestMode.result(mode: requestedMode, rooms: names)
            FreoSiriTrace.record("routing test result", detail: message)
            return message
        }
        #endif
        await restoreSavedSessionIfNeeded(retry: true)
        try requireSiriSession()
        guard !isBusy, let robot = selectedDevice else { throw ConnectorError.invalid("Another request is running. Try Siri again when it finishes.") }
        isBusy = true; defer { isBusy = false; reconcileLiveMap() }
        do {
            await awaitLiveRequestSlot()
            try Task.checkCancellation()
            let map = try await service.loadRooms(device: robot)
            try Task.checkCancellation()
            try requireSiriSession()
            guard let actualMapID = map.mapID, actualMapID > 0 else { throw ConnectorError.invalid("The robot did not return a saved map. Open Narwal to load it.") }
            let current = roomReferences(robot: robot, mapID: actualMapID, rooms: map.rooms, revision: map.mapRevision)
            applyRoomMap(map)
            let migrated = try siriCatalog?.resolve(references, current: current) ?? references
            let chosen = try SiriRoomReference.validate(requested: migrated, against: current)
            selectedRoomIDs = Set(chosen); mode = requestedMode; cleaningOptions = .standard; selectedTab = 0
            resetObservationWindow()
            invalidateCurrentTask()
            try await prepareForNewCleaning(robot: robot)
            let acknowledgement = try await service.command(device: robot, action: .start, mode: requestedMode, roomIDs: chosen)
            guard acknowledgement.accepted else { throw ConnectorError.invalid("The robot did not accept this request (code \(acknowledgement.resultCode)). It was not retried.") }
            let names = current.filter { chosen.contains($0.roomID) }.map(\.name).joined(separator: ", ")
            let result = "Request accepted: \(requestedMode.title) in \(names)."
            message = result
            return result
        } catch {
            message = error.localizedDescription
            rememberSession = await service.isSessionRemembered()
            if await service.sessionExpiration() == nil { clearPresentation(); selectedTab = 2 }
            throw error
        }
    }
    func siriCommand(action: RobotAction) async throws -> String {
        try Task.checkCancellation()
        guard action == .pause || action == .dock else {
            throw ConnectorError.invalid("Unsupported Siri robot command.")
        }
        #if DEBUG && FREO_SIRI_ROUTING_TESTS
        if FreoSiriRoutingTestMode.isActive {
            selectedTab = 0
            message = FreoSiriRoutingTestMode.actionResult(action: action)
            FreoSiriTrace.record("routing test result", detail: message)
            return message
        }
        #endif
        await restoreSavedSessionIfNeeded(retry: true)
        try requireSiriSession()
        guard !isBusy, let robot = selectedDevice else { throw ConnectorError.invalid("Another request is running. Try Siri again when it finishes.") }
        isBusy = true; defer { isBusy = false; reconcileLiveMap() }
        do {
            await awaitLiveRequestSlot()
            try Task.checkCancellation()
            try requireSiriSession()
            selectedTab = 0
            invalidateCurrentTask()
            let acknowledgement = try await service.command(device: robot, action: action, mode: mode, roomIDs: [])
            guard acknowledgement.accepted else { throw ConnectorError.invalid("The robot did not accept this request (code \(acknowledgement.resultCode)). It was not retried.") }
            if action == .dock { resetObservationWindow() }
            let result = action == .pause
                ? "Request accepted: Pause robot."
                : "Request accepted: Stop and return to dock."
            message = result
            return result
        } catch {
            message = error.localizedDescription
            rememberSession = await service.isSessionRemembered()
            if await service.sessionExpiration() == nil { clearPresentation(); selectedTab = 2 }
            throw error
        }
    }
    private func requireSiriSession() throws {
        if isDemo {
            selectedTab = 2
            message = "Switch Narwal to Live mode and sign in before using Siri. No robot command was sent."
            throw ConnectorError.invalid(message)
        }
        guard isAuthenticated, let expiry = sessionExpiry, expiry > Date() else {
            clearPresentation(preserveSiriCatalog: canRetrySavedSignIn)
            selectedTab = 2
            message = "Sign in to Narwal in Narwal, then ask Siri again. No robot command was sent."
            throw ConnectorError.invalid(message)
        }
        guard selectedDevice != nil else {
            selectedTab = 2
            message = "Select your robot in Narwal, then ask Siri again. No robot command was sent."
            throw ConnectorError.invalid(message)
        }
        guard selectedDevice?.canControl == true else { throw ConnectorError.invalid("The selected robot does not support cleaning commands in Narwal.") }
    }
    func applyRoomMap(_ map: RoomMap, footprint: Floorplan? = nil) {
        let candidate = footprint ?? floorplan
        let availableRooms: [RobotRoom]
        if let candidate, candidate.mapID == map.mapID,
           footprint != nil || (map.mapRevision != nil && candidate.mapRevision == map.mapRevision) {
            let present = Set(candidate.roomsWithArea.map(\.id))
            availableRooms = map.rooms.filter { present.contains($0.id) }
        } else { availableRooms = map.rooms }
        let revisionChanged = mapID == map.mapID && mapRevision != map.mapRevision
        let selection: Set<Int> = revisionChanged ? [] : RoomSelection.refreshed(previousMapID: mapID, selectedRoomIDs: selectedRoomIDs,
                                               currentMapID: map.mapID, availableRoomIDs: Set(availableRooms.map(\.id)))
        if mapID != map.mapID || revisionChanged {
            invalidateCurrentTask()
            resetSchedules()
            if liveMapState == .live || liveMapState == .waiting { stopLiveMap(); reconcileLiveMap() }
            floorplan = nil; isFloorplanCached = false; trajectory = nil; resetObservationWindow()
        }
        mapID = map.mapID; mapRevision = map.mapRevision; rooms = availableRooms; selectedRoomIDs = selection; roomsLoadedAt = Date()
        // Synthetic rooms must never trigger Siri's live entity/session lookup.
        if !isDemo { publishSiriRooms() }
    }
    private func roomReferences(robot: RobotDevice, mapID: Int, rooms: [RobotRoom], revision: UInt32?) -> [SiriRoomReference] {
        rooms.map { SiriRoomReference(productKey: robot.productKey, deviceID: robot.id, mapID: mapID, roomID: $0.id, name: $0.name, mapRevision: revision) }
    }
    private var shouldAutoReadCurrentTask: Bool {
        foreground && !roomEditorActive && !isDemo && isAuthenticated &&
            (lastCurrentTaskAttemptAt.map { currentTaskNow().timeIntervalSince($0) >= 30 } ?? true)
    }
    private func invalidateCurrentTask() {
        currentTaskGeneration = UUID(); currentTaskScope = nil
        currentTask = nil; currentTaskUpdatedAt = nil; currentTaskError = ""
        lastCurrentTaskAttemptAt = nil; lastPlan = nil
    }
    private func readCurrentTask(robot: RobotDevice, background: Bool = false) async throws {
        lastCurrentTaskAttemptAt = currentTaskNow(); isCurrentTaskLoading = true
        defer { isCurrentTaskLoading = false }
        do {
            let catalog = try await service.loadRooms(device: robot)
            try Task.checkCancellation()
            guard isAuthenticated, !isDemo, selectedDevice == robot,
                  let actualMapID = catalog.mapID, actualMapID > 0 else { throw CancellationError() }
            let keepEmptySelection = selectedRoomIDs.isEmpty
            applyRoomMap(catalog)
            // A read of the robot's task must never choose a future clean.
            if keepEmptySelection { selectedRoomIDs = [] }
            lastCurrentTaskAttemptAt = currentTaskNow()
            if background && isBusy { throw CancellationError() }
            let generation = currentTaskGeneration, scope = selectedTaskScope
            let plan = try await service.plan(device: robot)
            try Task.checkCancellation()
            guard isAuthenticated, !isDemo, selectedDevice == robot,
                  generation == currentTaskGeneration, scope == selectedTaskScope else { throw CancellationError() }
            guard (plan.resultCode == 1 && plan.mapID == actualMapID) ||
                    (plan.resultCode == 2 && plan.samples.isEmpty && plan.mapID == nil) else {
                throw ConnectorError.invalid("The current task did not match this robot’s saved map.")
            }
            lastPlan = plan
            if status?.workingCode == 1 && status?.isPaused != true { currentTask = nil }
            else { currentTask = CurrentCleaningTask.resolve(plan: plan, rooms: catalog.rooms, mapID: actualMapID) }
            currentTaskScope = scope; currentTaskUpdatedAt = currentTaskNow(); currentTaskError = ""
        } catch {
            if isAuthenticated, !isDemo, selectedDevice == robot {
                currentTaskError = "Current task could not be read. " + error.localizedDescription
            }
            throw error
        }
    }
    func refreshCurrentTask() async {
        guard !isDemo, isAuthenticated, let robot = selectedDevice else { return }
        await perform {
            do {
                self.status = try await self.service.status(device: robot)
                if self.status?.workingCode == 1 && self.status?.isPaused != true { self.invalidateCurrentTask() }
                else { try await self.readCurrentTask(robot: robot) }
                self.message = ""
            } catch {
                self.currentTaskError = "Current task could not be read. " + error.localizedDescription
                throw error
            }
        }
    }
    func checkPlan() async {
        if isDemo { message = "This is a simulated cleaning setup. No request reached Narwal."; return }
        guard let robot = selectedDevice else { return }
        await perform {
            self.supportsSweepIntensity = nil
            var diagnosticErrors: [String] = []
            do { self.status = try await self.service.status(device: robot) }
            catch { diagnosticErrors.append("Current suction could not be read: " + error.localizedDescription) }
            try await self.readCurrentTask(robot: robot)
            do { self.supportsSweepIntensity = try await self.service.sweepIntensitySupport(device: robot) }
            catch { diagnosticErrors.append("Suction capabilities could not be read: " + error.localizedDescription) }
            self.message = diagnosticErrors.joined(separator: " ")
        }
    }
    func send(action: RobotAction) async {
        guard !isBusy else { return }
        if action == .start && !canStart { message = "Select current saved rooms before starting."; return }
        if isDemo {
            invalidateCurrentTask()
            demoTask?.cancel()
            let code: Int = action == .start || action == .resume ? 4 : action == .pause ? 2 : 6
            status = .simulated(battery: status?.battery ?? 92, workingCode: code)
            message = ""
            if action == .dock {
                demoTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                    guard !Task.isCancelled, let self, self.isDemo else { return }
                    self.status = .simulated(battery: 92, workingCode: 10)
                }
            }
            return
        }
        guard let robot = selectedDevice, robot.canControl else { return }
        let chosen = rooms.map(\.id).filter(selectedRoomIDs.contains), chosenMode = mode, chosenOptions = cleaningOptions
        let references = mapID.map { roomReferences(robot: robot, mapID: $0, rooms: rooms, revision: mapRevision).filter { selectedRoomIDs.contains($0.roomID) } } ?? []
        await perform {
            var verifiedRoomIDs = chosen
            if action == .start {
                let currentMap = try await self.service.loadRooms(device: robot)
                try Task.checkCancellation()
                self.applyRoomMap(currentMap)
                guard let actualMapID = currentMap.mapID, actualMapID > 0 else {
                    throw ConnectorError.invalid("The robot did not return a saved map. Reload its rooms before starting.")
                }
                let current = self.roomReferences(robot: robot, mapID: actualMapID, rooms: currentMap.rooms, revision: currentMap.mapRevision)
                let migrated = try self.siriCatalog?.resolve(references, current: current) ?? references
                verifiedRoomIDs = try SiriRoomReference.validate(requested: migrated, against: current)
                try await self.prepareForNewCleaning(robot: robot)
            }
            if action == .start { self.resetObservationWindow() }
            self.invalidateCurrentTask()
            let acknowledgement = try await self.service.command(device: robot, action: action, mode: chosenMode, roomIDs: verifiedRoomIDs, options: chosenOptions)
            guard acknowledgement.accepted else {
                self.message = "The robot did not accept this command (code \(acknowledgement.resultCode)). It was not retried."
                return
            }
            self.message = "Request accepted."
            if action == .dock { self.resetObservationWindow() }
            do { self.status = try await self.service.status(device: robot) }
            catch { self.message += " Status could not be refreshed; check the robot before trying again." }
        }
    }
    /// Replace a confirmed active clean by using the already-supported recall
    /// action, then wait for both the task readback and status to confirm idle.
    /// An unknown task/status is a hard stop: never guess or send an unverified
    /// force-end command, and never start a second task while the first may run.
    private func prepareForNewCleaning(robot: RobotDevice) async throws {
        var currentStatus = try await service.status(device: robot)
        var currentPlan = try await service.plan(device: robot)
        switch TaskReplacementPolicy.initial(status: currentStatus, plan: currentPlan) {
        case .ready:
            return
        case .uncertain:
            throw ConnectorError.invalid("I couldn’t confirm whether a clean is running, so I didn’t send the new one. Refresh robot status and try again.")
        case .recall:
            let recalled = try await service.command(device: robot, action: .dock, mode: .vacuum, roomIDs: [])
            guard recalled.accepted else {
                throw ConnectorError.invalid("The current clean wasn’t confirmed stopped (code \(recalled.resultCode)); the new clean was not sent.")
            }
            message = "Returning the current clean to dock…"
        }
        for _ in 0..<45 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            currentStatus = try await service.status(device: robot)
            currentPlan = try await service.plan(device: robot)
            switch TaskReplacementPolicy.afterRecall(status: currentStatus, plan: currentPlan) {
            case .ready:
                return
            case .waiting:
                continue
            case .uncertain:
                throw ConnectorError.invalid("The robot’s stop state could not be verified; the new clean was not sent. Check the robot, then try again.")
            }
        }
        throw ConnectorError.invalid("The current clean is still returning to dock. The new clean was not sent; try again when the robot is on standby.")
    }
    func recheckNetwork() async {
        guard !isDemo else { message = "Demo mode makes no network requests."; return }
        await perform {
            self.networkExpires = try await self.service.recheckNetwork()
            self.message = ""
        }
    }
    func disconnect() {
        guard !isBusy else { return }
        isBusy = true
        try? siriCatalog?.remove()
        FreoSiriRoomIndex.refresh([])
        FreoShortcuts.updateAppShortcutParameters()
        clearPresentation(); savedLive = nil; message = ""
        canRetrySavedSignIn = false
        Task {
            await awaitLiveRequestSlot()
            do { try await service.disconnect(); savedSessionRemovalPending = false }
            catch { savedSessionRemovalPending = true; message = error.localizedDescription }
            isBusy = false
        }
    }
    func selectDevice(_ id: String) {
        guard !isBusy, devices.contains(where: { $0.id == id }) else { return }
        try? siriCatalog?.remove()
        FreoSiriRoomIndex.refresh([])
        stopLiveMap(); resetSchedules(); invalidateCurrentTask()
        roomEditGeneration = UUID(); roomEditSnapshot = nil
        selectedDeviceID = id; status = nil; rooms = []; selectedRoomIDs = []; floorplan = nil; isFloorplanCached = false; mapID = nil; mapRevision = nil; roomsLoadedAt = nil; lastPlan = nil
        supportsSweepIntensity = nil
        trajectory = nil; trajectoryError = ""; resetObservationWindow()
        cloudCleaningRecords = []; cloudHistoryPage = 0; hasMoreCloudHistory = true; cloudHistoryError = ""
        message = ""
        if let robot = selectedDevice { Task { await restoreCachedFloorplan(for: robot) } }
        reconcileLiveMap()
    }
    func toggleRoom(_ id: Int) {
        guard !isBusy, rooms.contains(where: { $0.id == id }) else { return }
        if selectedRoomIDs.contains(id) { selectedRoomIDs.remove(id) } else { selectedRoomIDs.insert(id) }
    }
    func selectAllRooms() { guard !isBusy else { return }; selectedRoomIDs = Set(rooms.map(\.id)) }
    func deselectAllRooms() { guard !isBusy else { return }; selectedRoomIDs = [] }
    func setDemo(_ value: Bool) {
        guard !isBusy, value != isDemo else { return }
        try? siriCatalog?.remove()
        FreoSiriRoomIndex.refresh([])
        stopLiveMap(); resetSchedules(); invalidateCurrentTask()
        roomEditGeneration = UUID(); roomEditSnapshot = nil
        demoTask?.cancel()
        if value {
            savedLive = SavedState(devices: devices, selectedID: selectedDeviceID, status: status, rooms: rooms, selected: selectedRoomIDs, mode: mode, cleaningOptions: cleaningOptions, floorplan: floorplan, plan: lastPlan, cached: isFloorplanCached, trajectory: trajectory, mapID: mapID, mapRevision: mapRevision, loadedAt: roomsLoadedAt, authenticated: isAuthenticated, expiry: sessionExpiry, rememberSession: rememberSession)
            isDemo = true; isAuthenticated = false; sessionExpiry = nil
            devices = [RobotDevice(id: "demo", productKey: "demo", name: "Freo X Ultra · Demo")]; selectedDeviceID = "demo"
            status = .simulated(battery: 92, workingCode: 10); floorplan = Self.demoMap(); isFloorplanCached = false; rooms = floorplan!.rooms
            selectedRoomIDs = []; mode = .vacuumMop; cleaningOptions = .standard; mapID = 1; mapRevision = nil; lastPlan = nil
            trajectory = nil; trajectoryError = ""; resetObservationWindow()
            message = ""
        } else {
            isDemo = false
            if let saved = savedLive {
                devices = saved.devices; selectedDeviceID = saved.selectedID; status = saved.status
                rooms = saved.rooms; selectedRoomIDs = saved.selected; mode = saved.mode; cleaningOptions = saved.cleaningOptions; floorplan = saved.floorplan; isFloorplanCached = saved.cached
                lastPlan = saved.plan; mapID = saved.mapID; mapRevision = saved.mapRevision; roomsLoadedAt = saved.loadedAt
                trajectory = saved.trajectory
                trajectoryError = saved.trajectory == nil ? "" : "Showing the last live route. It refreshes while this app is connected and open."
                isAuthenticated = saved.authenticated; sessionExpiry = saved.expiry
                rememberSession = saved.rememberSession
            } else { clearPresentation() }
            savedLive = nil; message = ""
            if let expiry = sessionExpiry, expiry <= Date() { disconnect() }
        }
        reconcileLiveMap()
    }
    private func restoreCachedFloorplan(for robot: RobotDevice) async {
        guard isAuthenticated, !isDemo, selectedDevice == robot, floorplan == nil,
              let cached = try? await floorplanCache?.load(device: robot),
              isAuthenticated, !isDemo, selectedDevice == robot, floorplan == nil,
              roomsLoadedAt == nil, mapID == nil else { return }
        // Local geometry is useful immediately, but never grants freshness for
        // Start, a robot pose, a current task, or an editable-map transaction.
        floorplan = cached.floorplan; rooms = cached.floorplan.roomsWithArea
        mapID = cached.floorplan.mapID; mapRevision = cached.floorplan.mapRevision
        roomsLoadedAt = nil; selectedRoomIDs = []; isFloorplanCached = true
        publishSiriRooms()
    }
    private func finishBackgroundRead() {
        backgroundReadInFlight = false
        let waiters = backgroundReadWaiters
        backgroundReadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func perform(quiet: Bool = false, _ operation: () async throws -> Void) async {
        guard !isBusy, !quiet || !backgroundReadInFlight else { return }
        if quiet { backgroundReadInFlight = true } else { isBusy = true }
        defer {
            if quiet { finishBackgroundRead() } else { isBusy = false }
            reconcileLiveMap()
        }
        await awaitLiveRequestSlot(waitForBackground: !quiet)
        do { try Task.checkCancellation(); try await operation() }
        catch {
            if !quiet { message = error.localizedDescription }
        }
        // A read after an accepted command can handle its own error. Always
        // reflect the service's actual retention state, including that case.
        if isAuthenticated {
            rememberSession = await service.isSessionRemembered()
            if await service.sessionExpiration() == nil { clearPresentation() }
        }
    }
    func clearPresentation(preserveSiriCatalog: Bool = false) {
        if !preserveSiriCatalog {
            try? siriCatalog?.remove()
            FreoSiriRoomIndex.refresh([])
        }
        stopLiveMap(); resetSchedules(); invalidateCurrentTask()
        roomEditGeneration = UUID()
        isAuthenticated = false; devices = []; selectedDeviceID = nil; status = nil
        rememberSession = false
        rooms = []; selectedRoomIDs = []; floorplan = nil; isFloorplanCached = false; lastPlan = nil
        supportsSweepIntensity = nil
        mapID = nil; mapRevision = nil; roomsLoadedAt = nil; sessionExpiry = nil
        roomEditSnapshot = nil; roomEditProgress = ""
        trajectory = nil; trajectoryError = ""; resetObservationWindow()
        cloudCleaningRecords = []; cloudHistoryPage = 0; hasMoreCloudHistory = true
    }
    private static func demoMap() -> Floorplan {
        let width = 100, height = 120
        let rooms = [RobotRoom(id: 1, name: "Living room"), RobotRoom(id: 2, name: "Kitchen"), RobotRoom(id: 3, name: "Bedroom")]
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 8..<112 { for x in 8..<92 {
            let room: UInt32 = y < 64 ? (x < 52 ? 1 : 2) : 3
            let exteriorWall = x == 8 || x == 91 || y == 8 || y == 111
            let verticalWall = y < 64 && x == 52 && !(30..<35).contains(y)
            let horizontalWall = y == 64 && !(35..<40).contains(x) && !(70..<75).contains(x)
            // Use the same wall/floor bits as a real map, including doorways,
            // so demo editing exercises the production adjacency checks.
            pixels[y * width + x] = (room << 8) | ((exteriorWall || verticalWall || horizontalWall) ? 0x20 : 0x01)
        } }
        return Floorplan(mapID: 1, width: width, height: height, resolution: 50, rooms: rooms, pixels: pixels)
    }
}
