import Foundation

private enum StoreMergeFixture {
    static func integer(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { let part = UInt8(value & 127); value >>= 7; data.append(part | (value == 0 ? 0 : 128)) } while value != 0
        return data
    }
    static func number(_ field: Int, _ value: UInt64) -> Data { integer(UInt64(field << 3)) + integer(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { integer(UInt64(field << 3 | 2)) + integer(UInt64(value.count)) + value }
    static func snapshot(merged: Bool = false, version: UInt32 = 38) -> MapSnapshot {
        let rooms = [RobotRoom(id: 1, name: "Kitchen"), RobotRoom(id: 2, name: "Hallway"), RobotRoom(id: 3, name: "Bathroom")]
            .filter { !merged || $0.id != 2 }
        let pixels: [UInt32] = merged ? [0x101, 0x101, 0x301, 0x101, 0x101, 0x301] : [0x101, 0x201, 0x301, 0x101, 0x201, 0x301]
        let map = Floorplan(mapID: 4, width: 3, height: 2, resolution: 60, rooms: rooms, pixels: pixels, mapRevision: version)
        var raw = number(1, 4) + number(2, 1) + number(3, 60) + number(4, 3) + number(5, 2)
        raw += bytes(6, number(1, 0) + number(2, 2) + number(3, 0) + number(4, 3))
        for room in rooms { raw += bytes(12, number(1, UInt64(room.id)) + number(2, 0) + bytes(3, Data(room.name.utf8))) }
        raw += number(33, UInt64(version)) + number(100, 70)
        return MapSnapshot(productKey: "EHf6cRNRGT", deviceID: String(repeating: "a", count: 32), mapID: 4,
            mapVersion: 1, editVersion: version, capturedAt: Date(), floorplan: map, staticMapPayload: raw)
    }
}

/// Real Store plus the in-memory fake service; no network transport is linked.
@MainActor func runRoomMergeStoreChecks() async throws {
    func check(_ value: Bool, _ message: String) { precondition(value, message) }
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        precondition(condition(), "Room-merge Store test did not settle")
    }
    func fails(_ operation: () async throws -> Void) async -> Bool {
        do { try await operation(); return false } catch { return true }
    }
    func connect(cache: FloorplanCache? = nil) async throws -> (FreoStore, Floorplan) {
        NarwalService.reset()
        let snapshot = StoreMergeFixture.snapshot()
        NarwalService.editableSnapshot = snapshot
        NarwalService.map = RoomMap(mapID: snapshot.mapID, rooms: snapshot.floorplan.rooms, mapRevision: snapshot.editVersion)
        let store = FreoStore(floorplanCache: cache)
        await store.signIn(email: "fixture@example.invalid", password: "unused fixture")
        store.applyRoomMap(NarwalService.map)
        store.roomEditorPresented(true)
        return (store, try await store.prepareRoomEditing())
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("freo-merge-cache-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FloorplanCache(directory: directory)
    let (store, baseline) = try await connect(cache: cache)
    let saved = StoreMergeFixture.snapshot(merged: true, version: 39)
    NarwalService.mapEditResult = .init(acknowledged: true, snapshot: saved, preservedSnapshotURL: directory.appendingPathComponent("fixture"))
    store.selectedRoomIDs = [1, 2]
    try await store.saveRoomMerge([1, 2], baseline: baseline)
    check(store.floorplan == saved.floorplan && store.rooms.map(\.id) == [1, 3] && store.selectedRoomIDs.isEmpty,
          "Successful merge must refresh exact returned geometry and clear old selections")
    check(store.mapRevision == 39 && !store.isBusy && store.trajectory == nil,
          "Successful merge must invalidate old revision/route bindings and release controls")
    let operations = NarwalService.mapEditOperations.first ?? []
    let isSingleMerge: Bool
    if operations.count == 1, case .merge(roomID1: 1, roomID2: 2, newRoomID: 1) = operations[0] { isSingleMerge = true }
    else { isSingleMerge = false }
    check(NarwalService.mapWriteAttempts == 1 && NarwalService.mapEditOperations.count == 1 && isSingleMerge,
          "Merge must send exactly one merge operation, without rename or retry")
    let cached = try await cache.load(device: NarwalService.robot)
    check(cached?.floorplan == saved.floorplan, "Successful merge must update the local map cache")
    let siri = try await store.siriRooms()
    check(siri.count == 2 && !siri.contains(where: { $0.name == "Hallway" }), "Siri must use the merged room catalog")
    let repeated = await fails { try await store.saveRoomMerge([1, 2], baseline: baseline) }
    check(repeated && NarwalService.mapWriteAttempts == 1, "A completed merge must invalidate the writable baseline")

    let (selectionStore, selectionBaseline) = try await connect()
    for ids: Set<Int> in [[1], [1, 2, 3], [1, 8], [1, 3]] {
        let invalid = await fails { try await selectionStore.saveRoomMerge(ids, baseline: selectionBaseline) }
        check(invalid && NarwalService.mapWriteAttempts == 0, "Invalid or non-adjoining selections must never send")
    }
    selectionStore.roomEditorPresented(false)
    let missing = await fails { try await selectionStore.saveRoomMerge([1, 2], baseline: selectionBaseline) }
    check(missing && NarwalService.mapWriteAttempts == 0, "A merge without its reviewed editable snapshot must fail")

    for paused in [false, true] {
        let (activeStore, activeBaseline) = try await connect()
        NarwalService.workingCode = paused ? 1 : 5
        NarwalService.isPaused = paused
        let rejected = await fails { try await activeStore.saveRoomMerge([1, 2], baseline: activeBaseline) }
        check(rejected && NarwalService.mapWriteAttempts == 0, "Cleaning or paused status must block a merge")
    }

    let (departedStore, departedBaseline) = try await connect()
    NarwalService.holdEditable = true
    let departing = Task { await fails { try await departedStore.saveRoomMerge([1, 2], baseline: departedBaseline) } }
    await settle { NarwalService.heldEditable != nil }
    NarwalService.workingCode = 5
    NarwalService.holdEditable = false; NarwalService.heldEditable?.resume(); NarwalService.heldEditable = nil
    let departed = await departing.value
    check(departed && NarwalService.mapWriteAttempts == 0, "Leaving standby after preflight must prevent the merge")

    let (staleStore, staleBaseline) = try await connect()
    NarwalService.editableSnapshot = StoreMergeFixture.snapshot(version: 39)
    let stale = await fails { try await staleStore.saveRoomMerge([1, 2], baseline: staleBaseline) }
    check(stale && NarwalService.mapWriteAttempts == 0 && staleStore.mapRevision == 39,
          "A stale revision must block writes and recover presentation read-only")

    let (uncertainStore, uncertainBaseline) = try await connect()
    NarwalService.mapEditFailure = ConnectorError.outcomeUnknown
    let unknown = await fails { try await uncertainStore.saveRoomMerge([1, 2], baseline: uncertainBaseline) }
    let retried = await fails { try await uncertainStore.saveRoomMerge([1, 2], baseline: uncertainBaseline) }
    check(unknown && retried && NarwalService.mapWriteAttempts == 1 && NarwalService.editableReads == 3,
          "Unknown merge outcome must recover read-only, invalidate its baseline, and never resend")

    let (closingStore, closingBaseline) = try await connect()
    NarwalService.holdEditable = true
    let closing = Task { await fails { try await closingStore.saveRoomMerge([1, 2], baseline: closingBaseline) } }
    await settle { NarwalService.heldEditable != nil }
    closingStore.roomEditorPresented(false)
    NarwalService.holdEditable = false; NarwalService.heldEditable?.resume(); NarwalService.heldEditable = nil
    let closed = await closing.value
    check(closed && NarwalService.mapWriteAttempts == 0, "Closing editor during preflight must prevent the merge")

    let (cancelStore, cancelBaseline) = try await connect()
    NarwalService.holdEditable = true
    let cancelling = Task { await fails { try await cancelStore.saveRoomMerge([1, 2], baseline: cancelBaseline) } }
    await settle { NarwalService.heldEditable != nil }
    cancelling.cancel()
    NarwalService.holdEditable = false; NarwalService.heldEditable?.resume(); NarwalService.heldEditable = nil
    let cancelled = await cancelling.value
    check(cancelled && NarwalService.mapWriteAttempts == 0 && !cancelStore.isBusy,
          "Cancellation before the merge must send nothing and release busy state")

    let (clearedStore, clearedBaseline) = try await connect()
    NarwalService.holdStatus = true
    let clearing = Task { await fails { try await clearedStore.saveRoomMerge([1, 2], baseline: clearedBaseline) } }
    await settle { NarwalService.heldStatus != nil }
    clearedStore.clearPresentation()
    NarwalService.holdStatus = false; NarwalService.heldStatus?.resume(); NarwalService.heldStatus = nil
    let cleared = await clearing.value
    check(cleared && NarwalService.mapWriteAttempts == 0 && clearedStore.floorplan == nil && clearedStore.rooms.isEmpty,
          "Disconnect while a standby read is pending must not send or revive the old map")

    NarwalService.reset()
    let demo = FreoStore(); demo.setDemo(true); demo.roomEditorPresented(true); demo.selectedTab = 1
    let demoBaseline = try await demo.prepareRoomEditing()
    check(demoBaseline.pixels.contains(where: { MapPixel(rawValue: $0).isWall }) &&
          demoBaseline.pixels.contains(where: { MapPixel(rawValue: $0).roomID > 0 && $0 & 0x30 == 0 }),
          "The synthetic map must contain correctly marked walls and reachable floor")
    demo.selectedRoomIDs = [1, 2]
    try await demo.saveRoomMerge([1, 2], baseline: demoBaseline)
    let expected = try RoomMergeTransaction.demoMergedFloorplan(floorplan: demoBaseline, sourceRoomIDs: [1, 2])
    await Task.yield()
    check(demo.floorplan == expected && demo.rooms.count == demoBaseline.rooms.count - 1 && demo.selectedRoomIDs.isEmpty,
          "Demo merge must preserve the union and remove exactly one room")
    check(zip(demoBaseline.pixels, expected.pixels).allSatisfy { ($0 ^ $1) & ~UInt32(0xff00) == 0 },
          "Demo merge must not change any structural pixel flags")
    check(demo.isDemo && demo.selectedTab == 1 && NarwalService.statusReads == 0 &&
          NarwalService.editableReads == 0 && NarwalService.mapWriteAttempts == 0,
          "Demo merge must remain offline on Floorplan")
    print("Room merge Store checks passed: single merge, cache/Siri refresh, standby/stale/baseline guards, uncertainty/no retry, editor/disconnect/cancellation scope, and offline demo.")
}
