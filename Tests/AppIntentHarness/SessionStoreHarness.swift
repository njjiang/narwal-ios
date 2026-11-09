import Foundation

/// Real FreoStore + in-memory fake NarwalService. Network transports and the
/// production session vault are deliberately not part of this executable.
@MainActor func runSessionStoreChecks() async throws {
    func check(_ value: Bool, _ message: String) { precondition(value, message) }
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        precondition(condition(), "Session Store check did not reach expected state")
    }
    func noMutation(_ message: String) {
        check(NarwalService.commands.isEmpty && NarwalService.mapWriteAttempts == 0, message)
    }

    NarwalService.reset()
    let empty = FreoStore()
    check(empty.rememberSession, "Sign-in must be remembered by default")
    await empty.restoreSavedSessionIfNeeded()
    await empty.restoreSavedSessionIfNeeded()
    check(NarwalService.restoreCalls == 1 && !empty.isAuthenticated && !empty.isBusy,
          "A startup with no saved session must run once and remain signed out")
    check(!empty.canRetrySavedSignIn && NarwalService.statusReads == 0 && NarwalService.mapReads == 0,
          "No saved session must not trigger robot reads or a retry prompt")
    noMutation("Startup without a session must not mutate the robot")

    NarwalService.reset()
    let restored = FreoStore()
    NarwalService.restoreDevices = [NarwalService.robot]
    NarwalService.remembered = true; NarwalService.holdRestore = true
    let first = Task { await restored.restoreSavedSessionIfNeeded() }
    await settle { NarwalService.heldRestore != nil }
    let second = Task { await restored.restoreSavedSessionIfNeeded() }
    for _ in 0..<30 { await Task.yield() }
    check(NarwalService.restoreCalls == 1 && restored.isBusy && !restored.isAuthenticated,
          "Concurrent startup/Siri restoration must share one pending service call")
    NarwalService.holdRestore = false
    NarwalService.heldRestore?.resume(); NarwalService.heldRestore = nil
    await first.value; await second.value
    check(restored.isAuthenticated && restored.devices == [NarwalService.robot] &&
          restored.selectedDeviceID == NarwalService.robot.id && restored.status?.battery == 80,
          "Restoration must recover account devices, selected robot, and fresh status")
    check(restored.rememberSession && restored.sessionExpiry == NarwalService.expiry &&
          restored.networkExpires == NarwalService.networkExpiry && !restored.canRetrySavedSignIn && !restored.isBusy,
          "Restoration must show actual retention/session/network state")
    check(NarwalService.statusReads == 1 && NarwalService.mapReads == 0 && NarwalService.liveMapReads == 0 &&
          NarwalService.liveSubscriptions == 0 && NarwalService.cloudPages.isEmpty,
          "Restoration alone must not start map, telemetry or history activity")
    await restored.restoreSavedSessionIfNeeded()
    check(NarwalService.restoreCalls == 1, "Repeated startup calls must not repeat a completed restore")
    noMutation("Restoration must never start, resume, pause, dock, or edit the robot")

    restored.disconnect()
    check(!restored.isAuthenticated && restored.devices.isEmpty && restored.selectedDeviceID == nil &&
          restored.status == nil && restored.sessionExpiry == nil && !restored.rememberSession && !restored.canRetrySavedSignIn,
          "Disconnect must clear remembered-session presentation immediately")
    await settle { !restored.isBusy }
    check(NarwalService.disconnectCalls == 1 && !NarwalService.remembered,
          "Disconnect must ask the service to clear its saved session")
    await restored.restoreSavedSessionIfNeeded()
    check(NarwalService.restoreCalls == 1 && !restored.isAuthenticated,
          "A disconnected completed startup must not silently restore again")
    noMutation("Disconnect after restoration must not issue a robot command")

    NarwalService.reset()
    let retry = FreoStore()
    NarwalService.restoreFailure = ConnectorError.invalid("Synthetic temporary connection failure")
    await retry.restoreSavedSessionIfNeeded()
    check(!retry.isAuthenticated && retry.canRetrySavedSignIn && !retry.message.isEmpty && !retry.isBusy,
          "A transient restore failure must expose an explicit retry")
    check(retry.networkExpires == NarwalService.networkExpiry,
          "The retry screen must show the current network-check expiration")
    await retry.restoreSavedSessionIfNeeded()
    check(NarwalService.restoreCalls == 1, "Transient restoration must not auto-loop")
    NarwalService.restoreFailure = nil; NarwalService.restoreDevices = [NarwalService.robot]; NarwalService.remembered = true
    await retry.restoreSavedSessionIfNeeded(retry: true)
    check(NarwalService.restoreCalls == 2 && retry.isAuthenticated && !retry.canRetrySavedSignIn && retry.message.isEmpty,
          "An explicit retry must recover a saved account and clear the retry error")
    noMutation("Retrying restoration must not issue a robot command")

    NarwalService.reset()
    let standard = FreoStore()
    await standard.signIn(email: "fixture@example.invalid", password: "unused fixture")
    check(NarwalService.signInRememberOptions == [true] && standard.rememberSession,
          "Default sign-in must persist the session")
    NarwalService.reset()
    let optedIn = FreoStore(); optedIn.rememberSession = true
    await optedIn.signIn(email: "fixture@example.invalid", password: "unused fixture")
    check(NarwalService.signInRememberOptions == [true] && optedIn.rememberSession,
          "The reviewed remember choice must reach the sign-in service")
    await optedIn.setRememberSession(false)
    await optedIn.setRememberSession(true)
    check(NarwalService.rememberedWrites == [false, true] && optedIn.rememberSession,
          "A connected user's retention changes must be applied and reflected")
    NarwalService.rememberFailure = ConnectorError.invalid("Synthetic storage failure")
    await optedIn.setRememberSession(false)
    check(optedIn.rememberSession && optedIn.savedSessionRemovalPending && !optedIn.message.isEmpty,
          "A failed retention change must not display an uncommitted preference")
    NarwalService.forgetBeforeFailure = true
    await optedIn.setRememberSession(false)
    check(!optedIn.rememberSession && optedIn.savedSessionRemovalPending,
          "Failed credential removal must show the service's disabled restoration state and a removal retry")
    NarwalService.rememberFailure = nil
    await optedIn.removeSavedSignIn()
    check(!optedIn.rememberSession && !optedIn.savedSessionRemovalPending && optedIn.message.isEmpty &&
          optedIn.isAuthenticated,
          "Successful removal retry must clear the pending error while preserving the connected account")
    let writes = NarwalService.rememberedWrites.count
    optedIn.setDemo(true)
    await optedIn.setRememberSession(false)
    check(NarwalService.rememberedWrites.count == writes,
          "Demo mode must not change live credential persistence")
    noMutation("Changing session retention must not mutate the robot")

    NarwalService.reset()
    let catalogDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: catalogDirectory) }
    let catalogCache = FloorplanCache(directory: catalogDirectory)
    let catalogMap = Floorplan(mapID: 4, width: 2, height: 2, resolution: 50,
        rooms: NarwalService.map.rooms + [.init(id: 3, name: "Removed room")],
        pixels: [0x101, 0x101, 0x201, 0x201], mapRevision: 38)
    try await catalogCache.save(floorplan: catalogMap, device: NarwalService.robot)
    let cachedRooms = FreoStore(floorplanCache: catalogCache)
    await cachedRooms.signIn(email: "fixture@example.invalid", password: "synthetic")
    cachedRooms.isBusy = true
    NarwalService.roomReadFailure = ConnectorError.invalid("Robot temporarily unreachable")
    let cachedChoices = try await cachedRooms.siriRooms()
    check(cachedChoices.map(\.name) == ["Kitchen", "Hallway"] && NarwalService.mapReads == 0,
          "Siri indexing must keep real cached rooms and exclude empty metadata during other app work without a robot request")
    cachedRooms.isBusy = false
    do {
        _ = try await cachedRooms.siriStart(mode: .vacuum, references: [cachedChoices[0]])
        preconditionFailure("Start must refresh and validate the current robot map")
    } catch {}
    check(NarwalService.commands.isEmpty,
          "Cached Siri choices must never authorize a command when fresh validation fails")

    NarwalService.reset()
    let statusUnavailable = FreoStore()
    NarwalService.restoreDevices = [NarwalService.robot]; NarwalService.remembered = true
    NarwalService.statusFailure = ConnectorError.invalid("Synthetic status unavailable")
    await statusUnavailable.restoreSavedSessionIfNeeded()
    check(statusUnavailable.isAuthenticated && statusUnavailable.status == nil &&
          statusUnavailable.message.contains("Status could not be read") && !statusUnavailable.canRetrySavedSignIn,
          "A status-read failure must not misreport a successfully restored account as signed out")
    noMutation("A status-read failure after restoration must not trigger any robot mutation")

    NarwalService.reset()
    let statusStorageFailure = FreoStore()
    NarwalService.restoreDevices = [NarwalService.robot]; NarwalService.remembered = true
    NarwalService.statusFailure = ConnectorError.invalid("Synthetic renewed-session save failure")
    NarwalService.forgetSessionOnRequestFailure = true
    await statusStorageFailure.restoreSavedSessionIfNeeded()
    check(statusStorageFailure.isAuthenticated && statusStorageFailure.selectedDeviceID == NarwalService.robot.id &&
          statusStorageFailure.sessionExpiry == NarwalService.expiry && !statusStorageFailure.rememberSession &&
          !statusStorageFailure.canRetrySavedSignIn && statusStorageFailure.message.contains("save failure"),
          "A first-status persistence failure must preserve valid in-memory auth and turn remembering off")
    noMutation("A first-status persistence failure must not issue a robot command")

    NarwalService.reset()
    let refreshStorageFailure = FreoStore(); refreshStorageFailure.rememberSession = true
    await refreshStorageFailure.signIn(email: "fixture@example.invalid", password: "unused fixture")
    NarwalService.statusFailure = ConnectorError.invalid("Synthetic refreshed-session save failure")
    NarwalService.forgetSessionOnRequestFailure = true
    await refreshStorageFailure.refreshStatus()
    check(refreshStorageFailure.isAuthenticated && !refreshStorageFailure.rememberSession &&
          refreshStorageFailure.status?.battery == 80 && refreshStorageFailure.sessionExpiry == NarwalService.expiry &&
          refreshStorageFailure.message.contains("save failure"),
          "A refresh persistence failure must keep connected auth and the last status while turning remembering off")
    noMutation("A refresh persistence failure must not automatically command the robot")

    NarwalService.reset()
    let commandStorageFailure = FreoStore(); commandStorageFailure.rememberSession = true
    await commandStorageFailure.signIn(email: "fixture@example.invalid", password: "unused fixture")
    NarwalService.commandFailure = ConnectorError.invalid("Synthetic command-session save failure")
    NarwalService.forgetSessionOnRequestFailure = true
    await commandStorageFailure.send(action: .pause)
    check(commandStorageFailure.isAuthenticated && !commandStorageFailure.rememberSession &&
          commandStorageFailure.sessionExpiry == NarwalService.expiry && commandStorageFailure.message.contains("save failure") &&
          NarwalService.commands.count == 1 && NarwalService.commands.first?.0 == .pause && NarwalService.statusReads == 1,
          "A requested command's persistence failure must retain valid auth, turn remembering off, and never retry")

    NarwalService.reset()
    let acceptedThenStorageFailure = FreoStore(); acceptedThenStorageFailure.rememberSession = true
    await acceptedThenStorageFailure.signIn(email: "fixture@example.invalid", password: "unused fixture")
    NarwalService.statusFailure = ConnectorError.invalid("Synthetic post-ack session save failure")
    NarwalService.forgetSessionOnRequestFailure = true
    await acceptedThenStorageFailure.send(action: .pause)
    check(acceptedThenStorageFailure.isAuthenticated && !acceptedThenStorageFailure.rememberSession &&
          acceptedThenStorageFailure.sessionExpiry == NarwalService.expiry &&
          acceptedThenStorageFailure.message.contains("Request accepted") &&
          acceptedThenStorageFailure.message.contains("Status could not be refreshed") &&
          NarwalService.commands.count == 1 && NarwalService.statusReads == 2,
          "A handled post-ACK save failure must preserve the acknowledgement, keep valid auth, turn remembering off, and never retry")

    for useStart in [false, true] {
        NarwalService.reset()
        let siriStorageFailure = FreoStore(); siriStorageFailure.rememberSession = true
        await siriStorageFailure.signIn(email: "fixture@example.invalid", password: "unused fixture")
        NarwalService.roomReadFailure = ConnectorError.invalid("Synthetic Siri refresh save failure")
        NarwalService.forgetSessionOnRequestFailure = true
        let reference = SiriRoomReference(productKey: NarwalService.robot.productKey, deviceID: NarwalService.robot.id,
                                          mapID: 4, roomID: 1, name: "Kitchen", mapRevision: 38)
        var rejected = false
        do {
            if useStart { _ = try await siriStorageFailure.siriStart(mode: .vacuum, references: [reference]) }
            else { _ = try await siriStorageFailure.siriRooms() }
        } catch { rejected = true }
        check(rejected && siriStorageFailure.isAuthenticated && !siriStorageFailure.rememberSession &&
              siriStorageFailure.sessionExpiry == NarwalService.expiry && !siriStorageFailure.isBusy &&
              siriStorageFailure.message.contains("Siri refresh save failure") &&
              NarwalService.mapReads == 1 && NarwalService.statusReads == 1,
              "Either Siri entry must retain valid auth, turn remembering off, and surface a refresh-save failure without retry")
        noMutation("A failed Siri room refresh must not automatically clean or issue any other robot mutation")
    }

    NarwalService.reset()
    let expired = FreoStore()
    NarwalService.restoreDevices = [NarwalService.robot]; NarwalService.remembered = true
    NarwalService.expireDuringStatusRead = true
    await expired.restoreSavedSessionIfNeeded()
    check(!expired.isAuthenticated && expired.devices.isEmpty && expired.selectedDeviceID == nil &&
          expired.status == nil && expired.sessionExpiry == nil && !expired.rememberSession &&
          !expired.message.isEmpty && !expired.isBusy,
          "Expiration during the first status read must discard the restored account presentation")
    noMutation("Expiration during restoration must not start a robot action")

    NarwalService.reset()
    let failedDisconnect = FreoStore()
    NarwalService.restoreDevices = [NarwalService.robot]; NarwalService.remembered = true
    await failedDisconnect.restoreSavedSessionIfNeeded()
    NarwalService.disconnectFailure = ConnectorError.invalid("Synthetic saved-session deletion failure")
    failedDisconnect.disconnect()
    check(!failedDisconnect.isAuthenticated && failedDisconnect.devices.isEmpty &&
          failedDisconnect.status == nil && !failedDisconnect.rememberSession,
          "Disconnect must clear account presentation before saved-session deletion finishes")
    await settle { !failedDisconnect.isBusy }
    check(failedDisconnect.message.contains("Synthetic saved-session deletion failure") &&
          !failedDisconnect.isAuthenticated && !failedDisconnect.canRetrySavedSignIn && failedDisconnect.savedSessionRemovalPending &&
          NarwalService.disconnectCalls == 1 && !NarwalService.remembered,
          "A deletion failure must remain signed out and show the service error")
    await failedDisconnect.restoreSavedSessionIfNeeded()
    check(NarwalService.restoreCalls == 1, "A failed deletion must not automatically restore the disconnected account")
    NarwalService.rememberFailure = ConnectorError.invalid("Synthetic retry deletion failure")
    await failedDisconnect.removeSavedSignIn()
    check(failedDisconnect.savedSessionRemovalPending && !failedDisconnect.isAuthenticated &&
          failedDisconnect.message.contains("Synthetic retry deletion failure"),
          "A failed removal retry must remain available and remain signed out")
    NarwalService.rememberFailure = nil
    await failedDisconnect.removeSavedSignIn()
    check(!failedDisconnect.savedSessionRemovalPending && !failedDisconnect.isAuthenticated &&
          !failedDisconnect.rememberSession && failedDisconnect.message.isEmpty && !failedDisconnect.isBusy &&
          NarwalService.rememberedWrites == [false, false],
          "A successful signed-out removal retry must clear its pending state and error")
    noMutation("A saved-session deletion failure must not mutate the robot")

    NarwalService.reset()
    let siriRestore = FreoStore()
    NarwalService.restoreDevices = [NarwalService.robot]; NarwalService.remembered = true
    NarwalService.holdRestore = true
    let startup = Task { await siriRestore.restoreSavedSessionIfNeeded() }
    await settle { NarwalService.heldRestore != nil }
    let roomQuery = Task { try await siriRestore.siriRooms() }
    for _ in 0..<30 { await Task.yield() }
    check(NarwalService.restoreCalls == 1 && NarwalService.mapReads == 0,
          "A concurrent Siri room query must wait for the shared restoration task")
    NarwalService.holdRestore = false
    NarwalService.heldRestore?.resume(); NarwalService.heldRestore = nil
    await startup.value
    let references = try await roomQuery.value
    check(references.count == 2 && NarwalService.restoreCalls == 1 && NarwalService.mapReads == 1 &&
          NarwalService.statusReads == 1 && siriRestore.isAuthenticated,
          "Siri may discover fresh rooms once shared startup restoration finishes")
    noMutation("Restoration and a Siri room query must not automatically clean or resume")

    print("Session Store checks passed: default saved sign-in, shared startup/Siri restoration, recovered account/status, no automatic robot mutations, explicit transient retry, retention changes/failure, demo isolation, disconnect success/failure, status failure/expiration, and persistence failure with valid in-memory auth. Fake service only; no network or Keychain linked.")
}
