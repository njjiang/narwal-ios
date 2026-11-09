import Foundation

/// Actual Store with the in-memory fake service. No network transport is linked.
@MainActor func runCurrentTaskStoreChecks() async throws {
    func check(_ value: Bool, _ message: String) { precondition(value, message) }
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        precondition(condition(), "Current-task Store check did not settle")
    }
    func plan(_ room: Int = 2, map: Int = 4) -> CleaningTaskSnapshot {
        .init(resultCode: 1, mapID: map, taskType: 2, optionFields: [:],
              samples: [.init(roomID: room, parameters: [1: 3])])
    }

    NarwalService.reset(); NarwalService.workingCode = 5; NarwalService.currentPlan = plan()
    var clock = Date()
    NarwalService.statusTimestamp = clock
    let store = FreoStore(currentTaskNow: { clock })
    await store.signIn(email: "fixture@example.invalid", password: "unused fixture")
    check(store.robotActivityTitle == "Connected" && store.currentTask == nil,
          "Raw State5 must not become a cleaning claim before verified task readback")
    await store.refreshCurrentTask()
    check(store.currentTaskIsFresh && store.currentTaskRoomIDs == [2] && store.selectedRoomIDs.isEmpty,
          "Actual task targets must resolve independently and must not select a future clean")
    check(store.currentTask?.modeNames == ["Mop"] && store.robotActivityTitle == "Cleaning task",
          "Fresh supported State5 task readback may label a cleaning task, not a physical cleaning location")
    store.selectedRoomIDs = [1]
    await store.refreshCurrentTask()
    check(store.currentTaskRoomIDs == [2] && store.selectedRoomIDs == [1],
          "Reading Hallway as active must preserve Kitchen selected for next clean")
    store.selectAllRooms(); check(store.selectedRoomIDs == [1, 2], "Select all must use current catalog")
    store.deselectAllRooms()
    check(store.selectedRoomIDs.isEmpty && store.currentTaskRoomIDs == [2],
          "Deselect all must only change the next clean")
    store.isBusy = true; store.selectAllRooms(); store.deselectAllRooms(); store.isBusy = false
    check(store.selectedRoomIDs.isEmpty, "Selection controls must respect an in-flight request")

    clock.addTimeInterval(46)
    check(!store.currentTaskIsFresh && store.currentTaskRoomIDs.isEmpty && store.robotActivityTitle == "Status unavailable",
          "A stale task/status must not remain an active highlight or StateN label")
    NarwalService.statusTimestamp = clock
    await store.refreshCurrentTask()
    NarwalService.planFailure = ConnectorError.invalid("Synthetic task unavailable")
    await store.refreshCurrentTask()
    check(store.currentTask?.rooms.map(\.id) == [2] && !store.currentTaskIsFresh && !store.currentTaskError.isEmpty,
          "A failed read may preserve the previous task only as stale/error")
    NarwalService.planFailure = nil; NarwalService.currentPlan = plan(map: 99)
    await store.refreshCurrentTask()
    check(!store.currentTaskIsFresh && store.currentTaskRoomIDs.isEmpty,
          "A current-task response for another map must not become verified")

    NarwalService.currentPlan = plan(); await store.refreshCurrentTask()
    let oldTimestamp = store.currentTaskUpdatedAt
    store.applyRoomMap(.init(mapID: 4, rooms: NarwalService.map.rooms, mapRevision: 39))
    check(store.currentTask == nil && store.currentTaskUpdatedAt == nil && store.currentTaskRoomIDs.isEmpty,
          "A revision change must discard task room identities, even if IDs are reused")
    NarwalService.map = .init(mapID: 4, rooms: NarwalService.map.rooms, mapRevision: 39)
    NarwalService.holdPlan = true
    let pending = Task { await store.refreshCurrentTask() }
    await settle { NarwalService.heldPlan != nil }
    store.applyRoomMap(.init(mapID: 4, rooms: NarwalService.map.rooms, mapRevision: 40))
    NarwalService.holdPlan = false; NarwalService.heldPlan?.resume(); NarwalService.heldPlan = nil
    await pending.value
    check(store.currentTask == nil && !store.currentTaskIsFresh && store.currentTaskUpdatedAt != oldTimestamp,
          "A late plan must not revive an invalidated map scope")

    NarwalService.map = .init(mapID: 4, rooms: NarwalService.map.rooms, mapRevision: 40)
    NarwalService.isPaused = true
    await store.refreshCurrentTask()
    check(store.robotActivityTitle == "Paused" && store.currentTaskRoomIDs == [2],
          "Paused state must remain distinct from the task's target rooms")
    NarwalService.isPaused = false; NarwalService.workingCode = 1
    let readsBeforeIdle = NarwalService.planReads
    await store.refreshStatus(quiet: true)
    check(store.currentTask == nil && store.robotActivityTitle == "Standby" && NarwalService.planReads == readsBeforeIdle,
          "Standby must clear a retained task without polling it into an active label")
    NarwalService.workingCode = 5
    await store.refreshCurrentTask()
    await store.send(action: .pause)
    check(store.currentTask == nil && NarwalService.commands.count == 1,
          "A deliberate command must invalidate prior task readback and must not retry")
    await store.refreshCurrentTask()
    store.setDemo(true)
    check(store.currentTask == nil && !store.currentTaskIsFresh, "Demo must not retain a real current task")
    store.setDemo(false)
    await store.refreshCurrentTask()
    let other = RobotDevice(id: String(repeating: "b", count: 32), productKey: "EHf6cRNRGT", name: "Other fixture")
    store.devices.append(other); store.selectDevice(other.id)
    check(store.currentTask == nil && store.currentTaskRoomIDs.isEmpty, "Device changes must discard task targets")

    NarwalService.reset(); NarwalService.workingCode = 5; NarwalService.currentPlan = plan()
    clock = Date(); NarwalService.statusTimestamp = clock
    let polling = FreoStore(currentTaskNow: { clock })
    await polling.signIn(email: "fixture@example.invalid", password: "unused fixture")
    await polling.refreshStatus(quiet: true)
    await polling.refreshStatus(quiet: true)
    clock.addTimeInterval(29); NarwalService.statusTimestamp = clock
    await polling.refreshStatus(quiet: true)
    check(NarwalService.planReads == 1, "Foreground status polls must throttle task reads to30 seconds")
    clock.addTimeInterval(1); NarwalService.statusTimestamp = clock
    await polling.refreshStatus(quiet: true)
    check(NarwalService.planReads == 2 && NarwalService.capabilityReads == 0,
          "The next eligible task poll must be read-only and omit capability queries")
    polling.foregroundChanged(false)
    clock.addTimeInterval(31); NarwalService.statusTimestamp = clock
    await polling.refreshStatus(quiet: true)
    check(NarwalService.planReads == 2, "Background status work must not auto-poll current tasks")
    await polling.checkPlan()
    check(NarwalService.planReads == 3 && NarwalService.capabilityReads == 1 && polling.message.isEmpty && polling.currentTaskIsFresh,
          "Manual diagnostics must refresh current task with one capability read and no noisy success banner")
    check(NarwalService.commands.isEmpty && NarwalService.mapWriteAttempts == 0,
          "Task reads, selection and polling must not issue robot mutations")

    NarwalService.reset(); NarwalService.workingCode = 5; NarwalService.currentPlan = plan()
    let at = Date(), points = [RobotPathPoint(x: 1, y: 1), .init(x: 2, y: 2)]
    let floor = Floorplan(mapID: 4, width: 10, height: 10, resolution: 60,
                         rooms: NarwalService.map.rooms, pixels: Array(repeating: 0x101, count: 100), mapRevision: 38)
    let snapshot = MapSnapshot(productKey: NarwalService.robot.productKey, deviceID: NarwalService.robot.id,
        mapID: 4, mapVersion: 1, editVersion: 38, capturedAt: at, floorplan: floor, staticMapPayload: Data())
    let route = RobotTrajectory(productKey: snapshot.productKey, deviceID: snapshot.deviceID, mapID: 4,
        mapVersion: 1, editVersion: 38, points: points, segments: [.init(id: 0, typeCode: 4, points: points)],
        pose: RobotPose(point: points.last!), capturedAt: at,
        deviceTimestampMilliseconds: UInt64(at.timeIntervalSince1970 * 1000), sequenceID: 1)
    NarwalService.liveMap = .init(snapshot: snapshot, trajectory: route)
    NarwalService.holdLivePreparation = true
    let race = FreoStore()
    await race.signIn(email: "fixture@example.invalid", password: "unused fixture")
    race.setMapVisible(true)
    await settle { NarwalService.heldLivePreparation != nil }
    race.selectedRoomIDs = [1]
    let read = Task { await race.refreshCurrentTask() }
    await settle { NarwalService.livePreparationCancelled }
    check(NarwalService.planReads == 0 && NarwalService.statusReads == 1 && race.isBusy,
          "A task read must wait for cancelled live preparation to release the service lock")
    NarwalService.holdLivePreparation = false
    NarwalService.heldLivePreparation?.resume(); NarwalService.heldLivePreparation = nil
    await read.value
    await settle { NarwalService.liveWaiter != nil }
    check(race.currentTaskRoomIDs == [2] && race.selectedRoomIDs == [1] && NarwalService.preparationBusyRejections == 0,
          "After cleanup, one task read must succeed and eligible live tracking may restart")
    check(race.currentPositionRoom?.id == 1 && race.currentTaskRoomIDs == [2],
          "Robot position and task targets must remain independent")
    race.devices.append(other); race.selectedDeviceID = other.id
    check(race.currentTaskRoomIDs.isEmpty && race.currentPositionRoom == nil,
          "Even a changed selection binding must not expose old robot task or position")
    race.setMapVisible(false); race.foregroundChanged(false)
    await settle { NarwalService.liveWaiter == nil }
    check(NarwalService.commands.isEmpty && NarwalService.mapWriteAttempts == 0,
          "The contention regression must never issue a robot command")
    NarwalService.reset()
    let silent = FreoStore()
    await silent.signIn(email: "fixture@example.invalid", password: "unused fixture")
    await silent.loadRooms()
    check(silent.selectedRoomIDs.isEmpty, "Initial live map load must select no rooms")
    silent.setDemo(true)
    check(silent.selectedRoomIDs.isEmpty, "Demo must start with no selected rooms")
    silent.setDemo(false)
    NarwalService.holdStatus = true
    let statusPoll = Task { await silent.refreshStatus(quiet: true) }
    await settle { NarwalService.heldStatus != nil }
    check(!silent.isBusy, "Routine status reads must not gray out controls")
    silent.toggleRoom(1)
    check(silent.selectedRoomIDs == [1], "Room selection stays responsive during a background read")
    let pause = Task { await silent.send(action: .pause) }
    await settle { silent.isBusy }
    check(NarwalService.commands.isEmpty, "Pause must wait for the in-flight read instead of racing it")
    NarwalService.holdStatus = false
    NarwalService.heldStatus?.resume(); NarwalService.heldStatus = nil
    await statusPoll.value; await pause.value
    check(NarwalService.commands.count == 1 && NarwalService.commands[0].0 == .pause,
          "A queued user command runs once after background refresh")
    silent.foregroundChanged(false)

    NarwalService.reset(); NarwalService.liveMap = .init(snapshot: snapshot, trajectory: route)
    let baseline = FreoStore()
    await baseline.signIn(email: "fixture@example.invalid", password: "unused fixture")
    await baseline.loadRooms()
    NarwalService.holdMapSnapshot = true
    baseline.setMapVisible(true)
    await settle { NarwalService.heldMapSnapshot != nil }
    check(!baseline.isBusy, "Map-baseline renewals must not gray out controls")
    baseline.toggleRoom(2)
    let dock = Task { await baseline.send(action: .dock) }
    await settle { baseline.isBusy }
    check(NarwalService.commands.isEmpty, "Dock must not race a map-baseline read")
    NarwalService.holdMapSnapshot = false
    NarwalService.heldMapSnapshot?.resume(); NarwalService.heldMapSnapshot = nil
    await dock.value
    check(NarwalService.commands.count == 1 && NarwalService.commands[0].0 == .dock,
          "Dock runs exactly once after the map read releases its slot")
    baseline.setMapVisible(false); baseline.foregroundChanged(false)
    await settle { NarwalService.liveWaiter == nil }

    NarwalService.reset(); NarwalService.workingCode = 5; NarwalService.currentPlan = plan()
    let switching = FreoStore()
    await switching.signIn(email: "fixture@example.invalid", password: "unused fixture")
    NarwalService.holdPlan = true
    let switchingPoll = Task { await switching.refreshStatus(quiet: true) }
    await settle { NarwalService.heldPlan != nil }
    switching.setMapVisible(true)
    switching.setDemo(true)
    NarwalService.holdPlan = false
    NarwalService.heldPlan?.resume(); NarwalService.heldPlan = nil
    await switchingPoll.value
    check(switching.isDemo && NarwalService.liveMapReads == 0 && switching.currentTaskError.isEmpty,
          "A silent read from the previous live scope must not continue into map requests or update demo errors")
    switching.setMapVisible(false); switching.foregroundChanged(false)

    let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("freo-store-cache-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let cache = FloorplanCache(directory: cacheDirectory)
    try await cache.save(floorplan: floor, device: NarwalService.robot)
    NarwalService.reset()
    let cachedStore = FreoStore(floorplanCache: cache)
    await cachedStore.signIn(email: "fixture@example.invalid", password: "unused fixture")
    check(cachedStore.floorplan == floor && cachedStore.isFloorplanCached && cachedStore.selectedRoomIDs.isEmpty,
          "A signed-in device may restore its local map without selecting rooms")
    cachedStore.toggleRoom(1)
    check(!cachedStore.canStart && cachedStore.trajectory == nil && cachedStore.currentTask == nil,
          "Cached geometry must not grant Start freshness or synthesize pose/current task")
    await cachedStore.loadRooms()
    check(cachedStore.canStart && cachedStore.selectedRoomIDs == [1],
          "A fresh matching room catalog can authorize Start without losing the user's selection")
    NarwalService.liveMap = .init(snapshot: snapshot, trajectory: route)
    await cachedStore.loadFloorplan()
    check(!cachedStore.isFloorplanCached && cachedStore.floorplan == floor,
          "A real map read replaces cached provenance")
    cachedStore.foregroundChanged(false)
    let unversioned = Floorplan(mapID: floor.mapID, width: floor.width, height: floor.height,
        resolution: floor.resolution, rooms: floor.rooms, pixels: floor.pixels, mapRevision: nil)
    try await cache.save(floorplan: unversioned, device: NarwalService.robot)
    NarwalService.map = .init(mapID: 4, rooms: floor.rooms, mapRevision: nil)
    let unversionedStore = FreoStore(floorplanCache: cache)
    await unversionedStore.signIn(email: "fixture@example.invalid", password: "unused fixture")
    await unversionedStore.loadRooms(); unversionedStore.toggleRoom(1)
    check(unversionedStore.isFloorplanCached && !unversionedStore.canStart,
          "An unversioned cached map cannot authorize Start from room metadata alone")
    unversionedStore.foregroundChanged(false)
    check(NarwalService.commands.isEmpty, "Cache restoration and validation must never send a command")
    print("Current-task Store checks passed: readback versus next selection, age/revision/device invalidation, stale/error handling, standby/paused labels,30-second read-only polling, deselect all, position scope cancelled live-startup serialization, silent reads with queued commands, empty defaults and cache freshness. Fake service only.")
}
