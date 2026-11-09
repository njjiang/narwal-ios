import Foundation

/// Exercises the actual Store with the fake service only. No MQTT or HTTP
/// transport is linked into this executable and no real robot can be reached.
@MainActor func runLiveStoreChecks() async throws {
    func check(_ value: Bool, _ message: String) { precondition(value, message) }
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        precondition(condition(), "Live Store task did not reach the expected state")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("freo-live-store-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FreoStore(historyStore: CleaningHistoryStore(directory: directory))
    NarwalService.reset(); NarwalService.workingCode = 2
    let at = Date()
    let map = Floorplan(mapID: 4, width: 10, height: 10, resolution: 60,
        rooms: NarwalService.map.rooms, pixels: Array(repeating: 0x101, count: 100), mapRevision: 38)
    let snapshot = MapSnapshot(productKey: NarwalService.robot.productKey, deviceID: NarwalService.robot.id,
        mapID: 4, mapVersion: 1, editVersion: 38, capturedAt: at, floorplan: map, staticMapPayload: Data())
    func route(_ points: [RobotPathPoint], receivedAt: Date = Date(), fresh: Bool = true, age: TimeInterval = 0, unavailable: String? = nil) -> RobotTrajectory {
        RobotTrajectory(productKey: snapshot.productKey, deviceID: snapshot.deviceID,
            mapID: 4, mapVersion: 1, editVersion: 38, points: points,
            segments: [.init(id: 0, typeCode: 4, points: points)], pose: points.last.map(RobotPose.init),
            capturedAt: receivedAt, deviceTimestampMilliseconds: fresh ? UInt64((receivedAt.timeIntervalSince1970 - age) * 1000) : 1,
            sequenceID: UInt64(receivedAt.timeIntervalSince1970 * 1000), unavailableReason: unavailable)
    }
    let points = [RobotPathPoint(x: 1, y: 1), .init(x: 2, y: 2)]
    NarwalService.liveMap = LiveMapSnapshot(snapshot: snapshot, trajectory: route(points, receivedAt: at))
    await store.signIn(email: "fixture@example.invalid", password: "unused fixture")
    check(NarwalService.liveSubscriptions == 0, "Signing in off the map must not open telemetry")
    store.setMapVisible(true)
    await settle { NarwalService.liveWaiter != nil }
    check(store.liveMapState == .waiting && !store.isBusy,
          "Activation is not live telemetry and must release the ordinary command lock")
    let handler = NarwalService.liveHandler!
    let pushed = route(points + [.init(x: 3, y: 3)])
    try await handler(.trajectory(pushed))
    check(store.liveMapState == .live && store.trajectory == pushed && store.lastLiveMapAt == pushed.capturedAt,
          "Only a scoped robot push should label the map live")
    try await handler(.trajectory(route(points, fresh: false)))
    check(store.liveMapState == .waiting && !store.trajectoryError.isEmpty,
          "A newly received stale pose must not be labelled live")
    try await handler(.trajectory(route(points, age: 20)))
    check(store.liveMapState == .waiting, "A 20 second delayed pose must not pass the stricter live freshness gate")
    try await handler(.trajectory(route(points, age: 20, unavailable: "Unsupported route format")))
    check(store.liveMapState == .waiting, "Unsupported route data must not bypass the live pose timestamp gate")
    try await handler(.trajectory(pushed))
    await store.send(action: .pause)
    check(NarwalService.commands.count == 1 && NarwalService.commands[0].0 == .pause,
          "An active reporting stream must not block a deliberate pause command")
    let commands = NarwalService.commands.count
    store.setMapVisible(false)
    await settle { NarwalService.liveWaiter == nil }
    check(store.liveMapState == .inactive && NarwalService.liveCancellations == 1,
          "Closing the map must cancel its stream")
    do { try await handler(.trajectory(route(points))); preconditionFailure("Late callback was accepted") } catch { }
    check(store.trajectory == pushed, "A cancelled stream must not overwrite the last shown path")

    store.setMapVisible(true)
    await settle { NarwalService.liveWaiter != nil }
    store.roomEditorPresented(true)
    await settle { NarwalService.liveWaiter == nil }
    check(store.liveMapState == .inactive, "The room editor must stop live reporting")
    store.roomEditorPresented(false)
    await settle { NarwalService.liveWaiter != nil }
    store.foregroundChanged(false)
    await settle { NarwalService.liveWaiter == nil }
    check(store.liveMapState == .inactive, "Backgrounding must stop live reporting")
    store.foregroundChanged(true)
    await settle { NarwalService.liveWaiter != nil }
    let previousDeviceHandler = NarwalService.liveHandler!
    let second = RobotDevice(id: String(repeating: "b", count: 32), productKey: "EHf6cRNRGT", name: "Other synthetic robot")
    store.devices.append(second)
    store.selectDevice(second.id); store.setMapVisible(false)
    await settle { NarwalService.liveWaiter == nil }
    do { try await previousDeviceHandler(.trajectory(pushed)); preconditionFailure("Cross-device callback was accepted") } catch { }
    check(store.trajectory == nil && store.liveMapState == .inactive,
          "Changing robots must clear and cancel the old telemetry scope")
    store.selectDevice(NarwalService.robot.id); store.setMapVisible(true)
    await settle { NarwalService.liveWaiter != nil }
    store.setDemo(true)
    await settle { NarwalService.liveWaiter == nil }
    check(store.isDemo && store.liveMapState == .inactive, "Demo must never retain a real reporting stream")
    store.setDemo(false)
    await settle { NarwalService.liveWaiter != nil }
    store.disconnect()
    await settle { NarwalService.liveWaiter == nil && !store.isBusy }
    check(!store.isAuthenticated && store.trajectory == nil && store.liveMapState == .inactive,
          "Disconnect must clear telemetry and reject late events")
    check(NarwalService.commands.count == commands, "Lifecycle transitions must never send a robot command")

    store.setMapVisible(false); store.foregroundChanged(false)
    NarwalService.reset(); NarwalService.liveMap = LiveMapSnapshot(snapshot: snapshot, trajectory: route(points, receivedAt: at))
    NarwalService.liveFailure = ConnectorError.invalid("Synthetic unsupported live reporting")
    await store.signIn(email: "fixture@example.invalid", password: "unused fixture")
    store.foregroundChanged(true); store.setMapVisible(true)
    await settle { store.liveMapState == .polling }
    check(store.liveMapMessage.contains("periodic reads") && !store.isBusy,
          "An unavailable stream must expose polling fallback without holding controls")
    for _ in 0..<100 { await Task.yield() }
    check(NarwalService.liveSubscriptions == 1, "A failed activation must not retry in a tight loop")
    store.setMapVisible(false); store.foregroundChanged(false)
    check(NarwalService.commands.isEmpty, "Testing telemetry failures must not invoke cleaning")
    print("Live Store checks passed: fresh-push-only labeling, controls during subscription, map/editor/background/device/demo/logout cancellation, late-event rejection, and bounded polling fallback. Fake service only.")
}
