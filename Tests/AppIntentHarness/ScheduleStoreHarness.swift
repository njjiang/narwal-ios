import Foundation

@MainActor
private enum ScheduleHarnessState {
    static var reads = 0
    static var writes = 0
    static var result: ScheduleContextSnapshot?
    static var writeError: Error?
    static var readError: Error?
}

@MainActor
extension NarwalService {
    func schedules(device: RobotDevice) async throws -> ScheduleContextSnapshot {
        ScheduleHarnessState.reads += 1
        if let error = ScheduleHarnessState.readError { throw error }
        return ScheduleHarnessState.result!
    }
    func saveSchedule(device: RobotDevice, draft: ScheduleDraft, existing: ScheduleEntry?, expectedContext: ScheduleContextSnapshot) async throws -> ScheduleContextSnapshot {
        try scheduleWrite()
    }
    func setScheduleEnabled(device: RobotDevice, entry: ScheduleEntry, enabled: Bool, expectedContext: ScheduleContextSnapshot) async throws -> ScheduleContextSnapshot {
        try scheduleWrite()
    }
    func deleteSchedule(device: RobotDevice, entry: ScheduleEntry, expectedContext: ScheduleContextSnapshot) async throws -> ScheduleContextSnapshot {
        try scheduleWrite()
    }
    private func scheduleWrite() throws -> ScheduleContextSnapshot {
        ScheduleHarnessState.writes += 1
        if let error = ScheduleHarnessState.writeError { throw error }
        return ScheduleHarnessState.result!
    }
}

@MainActor
func runScheduleStoreChecks() async throws {
    let store = FreoStore()
    NarwalService.reset()
    let device = NarwalService.robot
    let floorplan = Floorplan(mapID: 4, width: 2, height: 2, resolution: 5,
        rooms: NarwalService.map.rooms, pixels: [256,256,512,512], mapRevision: 38)
    let map = MapSnapshot(productKey: device.productKey, deviceID: device.id, mapID: 4,
        mapVersion: 1, editVersion: 38, capturedAt: Date(), floorplan: floorplan,
        staticMapPayload: NarwalCodec.encodeNumber(30, 1))
    let zone = RobotTimezone(identifier: "America/Los_Angeles", queryTimezone: "UTC-8", offsetSeconds: -28800)
    func context(timezone: RobotTimezone? = zone, primary: Int? = 4) -> ScheduleContextSnapshot {
        ScheduleContextSnapshot(snapshot: ScheduleSnapshot(entries: [], timezone: timezone?.displayName),
            map: map, timezone: timezone, queryTimezone: "UTC-8", primaryMapID: primary,
            deviceID: device.id, productKey: device.productKey)
    }
    func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    await store.loadSchedules()
    check(ScheduleHarnessState.reads == 0 && store.scheduleWriteUnavailableReason != nil,
          "Signed-out schedule loading must make no request")
    await store.signIn(email: "fixture@example.invalid", password: "unused fixture")
    ScheduleHarnessState.result = context()
    await store.loadSchedules()
    check(ScheduleHarnessState.reads == 1 && ScheduleHarnessState.writes == 0,
          "Viewing schedules must never create or change a schedule")
    check(store.scheduleCreateUnavailableReason == nil && store.rooms == map.floorplan.rooms,
          "Verified context should make real map rooms available to the editor")
    let draft = ScheduleDraft(name: "Offline fixture", enabled: false, hour: 10, minute: 15,
        weekdays: [1,3,5], mode: .vacuumThenMop, roomIDs: [1], mapID: 4)
    ScheduleHarnessState.writeError = ScheduleWriteError.outcomeUnknown
    let saved = await store.saveSchedule(draft: draft, existing: nil)
    check(!saved && ScheduleHarnessState.writes == 1 && store.scheduleWriteUncertain,
          "An uncertain write must latch and report failure without retry")
    _ = await store.saveSchedule(draft: draft, existing: nil)
    check(ScheduleHarnessState.writes == 1, "An uncertain write must block another save until a fresh review")
    ScheduleHarnessState.writeError = nil
    await store.loadSchedules()
    check(!store.scheduleWriteUncertain && store.scheduleCreateUnavailableReason == nil,
          "An explicit successful refresh must restore current schedule context")
    ScheduleHarnessState.readError = ConnectorError.invalid("Offline failed refresh")
    await store.loadSchedules()
    check(store.scheduleSnapshot != nil && store.scheduleContext == nil && store.scheduleWriteUnavailableReason != nil,
          "Failed refresh should preserve the last list while disabling stale writes")
    ScheduleHarnessState.readError = nil
    ScheduleHarnessState.result = context(timezone: nil)
    await store.loadSchedules()
    check(store.scheduleWriteUnavailableReason != nil, "Unknown robot timezone must not authorize scheduling")
    ScheduleHarnessState.result = context(primary: nil)
    await store.loadSchedules()
    check(store.scheduleCreateUnavailableReason != nil, "Unknown main-map identity must not authorize creation")

    let reads = ScheduleHarnessState.reads, writes = ScheduleHarnessState.writes
    store.setDemo(true)
    await store.loadSchedules()
    var demoDraft = draft
    demoDraft.mapID = store.floorplan?.mapID
    check(await store.saveSchedule(draft: demoDraft, existing: nil), "Demo creation should work locally")
    let demoEntry = store.scheduleSnapshot!.entries[0]
    check(await store.setScheduleEnabled(demoEntry, enabled: true), "Demo toggle should work locally")
    var edited = ScheduleDraft(entry: store.scheduleSnapshot!.entries[0]); edited.hour = 18; edited.weekdays = [2,4]
    check(await store.saveSchedule(draft: edited, existing: store.scheduleSnapshot!.entries[0]), "Demo edit should work locally")
    check(store.scheduleSnapshot!.entries[0].hour == 18 && store.scheduleSnapshot!.entries[0].weekdays == [2,4],
          "Demo edit must display the changed recurrence")
    check(await store.deleteSchedule(store.scheduleSnapshot!.entries[0]), "Demo deletion should work locally")
    check(store.scheduleSnapshot!.entries.isEmpty && ScheduleHarnessState.reads == reads && ScheduleHarnessState.writes == writes,
          "All demo schedule operations must remain disconnected from Narwal")
    store.setDemo(false)
    check(store.scheduleSnapshot == nil && store.scheduleContext == nil,
          "Leaving demo must not transplant simulated schedules into the real device")
    ScheduleHarnessState.result = context()
    await store.loadSchedules()
    store.selectDevice(device.id)
    check(store.scheduleSnapshot == nil, "Selecting a robot must invalidate the previous schedule context")
    print("Real-store schedule checks passed: read-only load, uncertain-write latch, stale-read protection, timezone/main-map gates, local demo CRUD and device isolation. Fake service only.")
}
