import Foundation

private enum StoreRenameFixture {
    static func integer(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { let part = UInt8(value & 127); value >>= 7; data.append(part | (value == 0 ? 0 : 128)) } while value != 0
        return data
    }
    static func number(_ field: Int, _ value: UInt64) -> Data { integer(UInt64(field << 3)) + integer(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { integer(UInt64(field << 3 | 2)) + integer(UInt64(value.count)) + value }
    static func snapshot(names: [String] = ["Kitchen", "Hallway"], version: UInt32 = 38) -> MapSnapshot {
        let rooms = names.enumerated().map { RobotRoom(id: $0.offset + 1, name: $0.element) }
        let map = Floorplan(mapID: 4, width: 2, height: 2, resolution: 60, rooms: rooms, pixels: [0x101, 0x101, 0x201, 0x201], mapRevision: version)
        var raw = number(1, 4) + number(2, 1) + number(3, 60) + number(4, 2) + number(5, 2)
        raw += bytes(6, number(1, 0) + number(2, 2) + number(3, 0) + number(4, 2))
        for room in rooms { raw += bytes(12, number(1, UInt64(room.id)) + number(2, 0) + bytes(3, Data(room.name.utf8))) }
        raw += number(33, UInt64(version)) + number(100, 70)
        return MapSnapshot(productKey: "EHf6cRNRGT", deviceID: String(repeating: "a", count: 32), mapID: 4,
            mapVersion: 1, editVersion: version, capturedAt: Date(), floorplan: map, staticMapPayload: raw)
    }
}

/// Exercises the real Store; only an in-memory fake service is linked.
@MainActor func runRoomNamesStoreChecks() async throws {
    func check(_ value: Bool, _ message: String) { precondition(value, message) }
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        precondition(condition(), "Room-name Store test did not settle")
    }
    func fails(_ operation: () async throws -> Void) async -> Bool {
        do { try await operation(); return false } catch { return true }
    }
    func connect(cache: FloorplanCache? = nil) async throws -> (FreoStore, Floorplan) {
        NarwalService.reset()
        NarwalService.editableSnapshot = StoreRenameFixture.snapshot()
        let store = FreoStore(floorplanCache: cache)
        await store.signIn(email: "fixture@example.invalid", password: "unused fixture")
        store.applyRoomMap(NarwalService.map)
        store.roomEditorPresented(true)
        return (store, try await store.prepareRoomEditing())
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("freo-rename-cache-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FloorplanCache(directory: directory)
    let (store, baseline) = try await connect(cache: cache)
    let saved = StoreRenameFixture.snapshot(names: ["Entry", "Hallway"], version: 39)
    NarwalService.mapEditResult = .init(acknowledged: true, snapshot: saved, preservedSnapshotURL: directory.appendingPathComponent("fixture"))
    store.selectedRoomIDs = [1]
    try await store.saveRoomNames([1: "Entry", 2: "Hallway"], baseline: baseline)
    check(store.rooms.map(\.name) == ["Entry", "Hallway"] && store.floorplan?.pixels == baseline.pixels,
          "Successful rename must refresh the catalog without changing pixels")
    check(store.mapRevision == 39 && store.selectedRoomIDs.isEmpty,
          "Rename must invalidate old selection and revision-based bindings")
    check(NarwalService.mapWriteAttempts == 1 && NarwalService.mapEditOperations.first?.count == 1,
          "Rename must send exactly one changed-name operation")
    let cached = try await cache.load(device: NarwalService.robot)
    check(cached?.floorplan == saved.floorplan, "Successful rename must update the local map cache")
    let siri = try await store.siriRooms()
    check(siri.first?.name == "Entry", "Siri must resolve the new room name")

    let (unchangedStore, unchanged) = try await connect()
    let reads = NarwalService.editableReads
    try await unchangedStore.saveRoomNames([1: "Kitchen", 2: "Hallway"], baseline: unchanged)
    check(NarwalService.mapWriteAttempts == 0 && NarwalService.editableReads == reads,
          "An unchanged names form must make no save request")
    let invalid = await fails { try await unchangedStore.saveRoomNames([1: "Hallway"], baseline: unchanged) }
    check(invalid && NarwalService.mapWriteAttempts == 0, "A duplicate name must fail before a write")

    for paused in [false, true] {
        let (activeStore, activeBaseline) = try await connect()
        NarwalService.workingCode = paused ? 1 : 5
        NarwalService.isPaused = paused
        let rejected = await fails { try await activeStore.saveRoomNames([1: "Entry"], baseline: activeBaseline) }
        check(rejected && NarwalService.mapWriteAttempts == 0,
              "Cleaning or paused status must prevent room-name writes")
    }

    let (departedStore, departedBaseline) = try await connect()
    NarwalService.holdEditable = true
    let departing = Task { await fails { try await departedStore.saveRoomNames([1: "Entry"], baseline: departedBaseline) } }
    await settle { NarwalService.heldEditable != nil }
    NarwalService.workingCode = 5
    NarwalService.holdEditable = false; NarwalService.heldEditable?.resume(); NarwalService.heldEditable = nil
    let leftStandby = await departing.value
    check(leftStandby && NarwalService.mapWriteAttempts == 0,
          "A robot leaving standby after preflight must still be blocked immediately before the write")

    let (staleStore, staleBaseline) = try await connect()
    NarwalService.editableSnapshot = StoreRenameFixture.snapshot(version: 39)
    let staleRejected = await fails { try await staleStore.saveRoomNames([1: "Entry"], baseline: staleBaseline) }
    check(staleRejected && NarwalService.mapWriteAttempts == 0 && staleStore.mapRevision == 39,
          "A changed revision must prevent a write and recover the fresh map read-only")

    let (uncertainStore, uncertainBaseline) = try await connect()
    NarwalService.mapEditFailure = ConnectorError.outcomeUnknown
    let unknown = await fails { try await uncertainStore.saveRoomNames([1: "Entry"], baseline: uncertainBaseline) }
    let retried = await fails { try await uncertainStore.saveRoomNames([1: "Entry"], baseline: uncertainBaseline) }
    check(unknown && retried && NarwalService.mapWriteAttempts == 1 && NarwalService.editableReads == 3,
          "An uncertain write must read back once, discard its baseline, and never resend")

    let (closingStore, closingBaseline) = try await connect()
    NarwalService.holdEditable = true
    let closing = Task { await fails { try await closingStore.saveRoomNames([1: "Entry"], baseline: closingBaseline) } }
    await settle { NarwalService.heldEditable != nil }
    closingStore.roomEditorPresented(false)
    NarwalService.holdEditable = false; NarwalService.heldEditable?.resume(); NarwalService.heldEditable = nil
    let closed = await closing.value
    check(closed && NarwalService.mapWriteAttempts == 0,
          "Closing the editor during preflight must prevent the pending write")

    let (cancelStore, cancelBaseline) = try await connect()
    NarwalService.holdEditable = true
    let cancelling = Task { await fails { try await cancelStore.saveRoomNames([1: "Entry"], baseline: cancelBaseline) } }
    await settle { NarwalService.heldEditable != nil }
    cancelling.cancel()
    NarwalService.holdEditable = false; NarwalService.heldEditable?.resume(); NarwalService.heldEditable = nil
    let cancelled = await cancelling.value
    check(cancelled && NarwalService.mapWriteAttempts == 0 && !cancelStore.isBusy,
          "Cancellation before write must release busy state without sending")

    let (clearedStore, _) = try await connect()
    NarwalService.holdEditable = true
    let loading = Task { await fails { _ = try await clearedStore.prepareRoomEditing() } }
    await settle { NarwalService.heldEditable != nil }
    clearedStore.clearPresentation()
    NarwalService.holdEditable = false; NarwalService.heldEditable?.resume(); NarwalService.heldEditable = nil
    let loadRejected = await loading.value
    check(loadRejected && clearedStore.floorplan == nil && clearedStore.rooms.isEmpty,
          "An editable response arriving after disconnect must not revive the old robot")

    NarwalService.reset()
    let demo = FreoStore(); demo.setDemo(true); demo.roomEditorPresented(true); demo.selectedTab = 1
    let demoBaseline = try await demo.prepareRoomEditing()
    try await demo.saveRoomNames([1: "Entry"], baseline: demoBaseline)
    await Task.yield()
    check(demo.rooms.first?.name == "Entry" && demo.floorplan?.pixels == demoBaseline.pixels &&
          NarwalService.statusReads == 0 && NarwalService.editableReads == 0 && NarwalService.mapWriteAttempts == 0,
          "Demo rename must preserve pixels without contacting the service")
    check(demo.isDemo && demo.selectedTab == 1 && demo.message == "Room names saved.",
          "Demo rename must remain on Floorplan without a live Siri sign-in prompt")
    print("Room names Store checks passed: names-only writes, cache/Siri refresh, standby/stale guards, single-send uncertainty, editor/disconnect/cancellation scope, and offline demo.")
}
