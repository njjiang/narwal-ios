import Foundation
import CoreFoundation

/// Session ownership and device validation stay outside the presentation layer.
/// Session persistence is opt-in and device-only. Passwords are never stored.
/// Mutations are explicit and never retried.
public actor NarwalService {
    struct Session: Codable, Sendable {
        let issuedAt: Date
        let uuid: String
        let token: String
        let refresh: String?
        let tokenExpires: Date
        let expires: Date
    }
    private struct CachedRooms { let map: RoomMap; let expires: Date }
    private let policy: any SessionNetworkPolicy
    private let vault: any SessionVault
    private let http: SessionHTTPClient
    private let now: @Sendable () -> Date
    private var rememberSession = false
    private var session: Session?
    private var pendingRestoration: Session?
    private var devices: [RobotDevice] = []
    private var rooms: [String: CachedRooms] = [:]
    var busy = false
    var generation = 0
    var scheduleUncertainDevices = Set<String>()
    private var expiryTask: Task<Void, Never>?
    private var exchangeTask: Task<Data, Error>?
    private var httpTask: Task<Data, Error>?
    private var liveTask: Task<Void, Error>?
    private var liveID: UUID?
    public init() {
        policy = USNetworkPolicy(); vault = KeychainSessionVault(); now = { Date() }
        http = { destination, method, path, headers, body, preflight in
            try await PinnedHTTP.request(destination: destination, method: method, path: path,
                                         headers: headers, body: body, preflight: preflight)
        }
    }
    // Offline tests replace every credential-bearing dependency, including Keychain.
    init(vault: any SessionVault, policy: any SessionNetworkPolicy,
         now: @escaping @Sendable () -> Date = { Date() }, http: @escaping SessionHTTPClient) {
        self.vault = vault; self.policy = policy; self.now = now; self.http = http
    }

    public func networkExpiration() async -> Date { await policy.expiration() }
    public func sessionExpiration() -> Date? { session?.expires }
    public func recheckNetwork() async throws -> Date {
        try begin(); defer { busy = false }
        return try await policy.recheck()
    }
    public func signIn(email: String, password: String, rememberSession: Bool = false) async throws -> [RobotDevice] {
        try begin(); defer { busy = false }
        clear(); try vault.remove()
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, email.utf8.count <= 320, !password.isEmpty, password.utf8.count <= 2048 else { throw ConnectorError.invalid("Enter your Narwal email and separate Narwal password.") }
        let current = generation
        do {
            if await policy.expiration() <= now() { _ = try await policy.recheck() }
            try check(current)
            let data = try await request(path: "/user-authentication-server/v2/login/loginByEmail", method: "POST", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
            try check(current)
            let next = try Self.decodeSession(data, now: now())
            session = next
            let found = try await request(path: "/user-device-platform-server/device-info/getDeviceInfoList", method: "GET", token: next.token)
            try check(current); try requireUnexpiredSession()
            devices = try Self.decodeDevices(found)
            if rememberSession {
                do {
                    try vault.save(try Self.savedSessionData(next))
                    self.rememberSession = true
                } catch {
                    scheduleExpiry(current)
                    throw SessionStorageFailure()
                }
            }
            scheduleExpiry(current)
            return devices
        } catch { if current == generation, !(error is SessionStorageFailure) { clear(); try? vault.remove() }; throw error }
    }
    public func disconnect() throws { clear(); try vault.remove() }
    public func isSessionRemembered() -> Bool { vault.isEnabled() }
    public func setSessionRemembered(_ enabled: Bool) throws {
        try begin(); defer { busy = false }
        if !enabled { rememberSession = false; pendingRestoration = nil; try vault.remove(); return }
        try requireUnexpiredSession()
        guard let access = session else { throw ConnectorError.invalid("Sign in before saving this session.") }
        try vault.save(try Self.savedSessionData(access)); rememberSession = true
    }
    /// Restores only a still-valid local session, after verifying public US
    /// destinations. Fresh device discovery establishes the account's scope.
    public func restoreSession() async throws -> [RobotDevice]? {
        try begin(); defer { busy = false }
        if session != nil { try check(generation); try requireUnexpiredSession(); return devices }
        let restored: Session
        if let pending = pendingRestoration {
            guard pending.expires > now() else { clear(); try? vault.remove(); throw SessionRestoreFailure.expired }
            restored = pending
        } else {
            guard let data = try vault.load() else { return nil }
            do { restored = try Self.decodeSavedSession(data, now: now()) }
            catch { clear(); try vault.remove(); throw error }
        }
        let current = generation
        do {
            if await policy.expiration() <= now() { _ = try await policy.recheck() }
            _ = try await policy.destination(.https)
            try check(current)
            guard restored.expires > now() else { throw SessionRestoreFailure.expired }
            session = restored; pendingRestoration = nil; rememberSession = vault.isEnabled()
            let access = try await accessToken(current)
            let found = try await request(path: "/user-device-platform-server/device-info/getDeviceInfoList", method: "GET", token: access.token)
            try check(current); try requireUnexpiredSession()
            try Self.checkAccountResponse(found)
            do { devices = try Self.decodeDevices(found) }
            catch { throw SessionRestoreFailure.invalidIdentity }
            scheduleExpiry(current)
            return devices
        } catch {
            if current == generation {
                let retainPending = !Self.invalidatesSavedSession(error) &&
                    (error is SessionStorageFailure || !vault.isEnabled())
                let pending = retainPending ? (session ?? pendingRestoration) : nil
                clear()
                if Self.invalidatesSavedSession(error) { try? vault.remove() }
                pendingRestoration = pending
                if pending != nil { scheduleExpiry(generation) }
            }
            throw error
        }
    }
    public func status(device: RobotDevice) async throws -> RobotStatus {
        try begin(); defer { busy = false }
        let raw = try await query(device, topic: "status/get_device_base_status")
        return try NarwalCodec.status(raw)
    }
    public func loadRooms(device: RobotDevice) async throws -> RoomMap {
        try begin(); defer { busy = false }
        let current = generation
        let raw = try await query(device, topic: "map/get_map")
        try check(current)
        let map = try NarwalCodec.rooms(raw)
        rooms[device.id] = CachedRooms(map: map, expires: Date().addingTimeInterval(900))
        return map
    }
    public func floorplan(device: RobotDevice) async throws -> Floorplan {
        try begin(); defer { busy = false }
        let current = generation
        let raw = try await query(device, topic: "map/get_map")
        try check(current)
        let map = try NarwalCodec.floorplan(raw)
        rooms[device.id] = CachedRooms(map: RoomMap(mapID: map.mapID, rooms: map.rooms, mapRevision: map.mapRevision), expires: Date().addingTimeInterval(900))
        return map
    }
    /// Reads an exact versioned snapshot through the existing map endpoint.
    /// It does not write the robot's map or claim that the snapshot is restorable.
    public func mapSnapshot(device: RobotDevice) async throws -> MapSnapshot {
        try begin(); defer { busy = false }
        let current = generation
        let raw = try await query(device, topic: "map/get_map")
        try check(current)
        return try NarwalCodec.mapSnapshot(raw, device: device)
    }
    /// One read supplies the floorplan and route in the same coordinate frame.
    /// Unsupported route data never changes or fabricates the saved floorplan.
    public func liveMapSnapshot(device: RobotDevice) async throws -> LiveMapSnapshot {
        try begin(); defer { busy = false }
        let current = generation
        let raw = try await query(device, topic: "map/get_map")
        try check(current)
        let snapshot = try NarwalCodec.mapSnapshot(raw, device: device)
        rooms[device.id] = CachedRooms(map: RoomMap(mapID: snapshot.mapID,
            rooms: snapshot.floorplan.rooms, mapRevision: snapshot.editVersion),
            expires: Date().addingTimeInterval(900))
        let route: RobotTrajectory
        do { route = try NarwalCodec.trajectory(snapshot: snapshot) }
        catch {
            route = RobotTrajectory(productKey: snapshot.productKey, deviceID: snapshot.deviceID,
                mapID: snapshot.mapID, mapVersion: snapshot.mapVersion, editVersion: snapshot.editVersion,
                points: [], segments: [], pose: nil, capturedAt: snapshot.capturedAt,
                deviceTimestampMilliseconds: nil, sequenceID: nil,
                unavailableReason: "The robot’s route could not be read. Refresh the floorplan to try again.")
        }
        return LiveMapSnapshot(snapshot: snapshot, trajectory: route)
    }
    /// Telemetry owns a separate socket/task. Only its initial token preparation
    /// briefly takes the ordinary request lock; observing never blocks controls.
    public func observeLiveWindow(device: RobotDevice, baseline: LiveMapSnapshot,
                                  onEvent: @escaping @Sendable (LiveTelemetryEvent) async throws -> Void) async throws {
        try begin()
        let current = generation, id = UUID()
        let pending: Task<Void, Error>
        do {
            try validate(device)
            guard liveTask == nil, baseline.snapshot.matches(device: device, mapID: baseline.snapshot.mapID),
                  baseline.snapshot.capturedAt.timeIntervalSinceNow <= 5,
                  baseline.snapshot.capturedAt.timeIntervalSinceNow >= -60 else {
                throw ConnectorError.invalid("Reload the current robot map before opening live tracking.")
            }
            let access = try await accessToken(current)
            let destination = try await policy.destination(.mqtt)
            try check(current); try validate(device)
            liveID = id
            pending = Task {
                try await NarwalLiveMQTT.observeWindow(destination: destination, uuid: access.uuid,
                    token: access.token, device: device, baseline: baseline,
                    preflight: { try await self.livePreflight(device: device, generation: current,
                                                            id: id, tokenExpires: access.tokenExpires,
                                                            destination: destination) },
                    onEvent: onEvent)
            }
            liveTask = pending
            busy = false
        } catch { busy = false; throw error }
        defer { if liveID == id { liveTask = nil; liveID = nil } }
        try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
        try check(current)
    }
    public func stopLiveTelemetry() {
        liveID = nil; liveTask?.cancel(); liveTask = nil
    }
    private func livePreflight(device: RobotDevice, generation current: Int, id: UUID, tokenExpires: Date,
                               destination: VerifiedDestination) async throws {
        try check(current); try validate(device)
        guard liveID == id, tokenExpires > Date() else { throw ConnectorError.invalid("Live tracking needs a renewed session.") }
        let currentDestination = try await policy.destination(.mqtt)
        try check(current); try validate(device)
        guard liveID == id, tokenExpires > Date(), currentDestination.host == destination.host,
              currentDestination.port == destination.port, currentDestination.address == destination.address else {
            throw ConnectorError.invalid("Live tracking needs the current verified connection.")
        }
    }
    /// Narwal's own paged cleaning records. This is HTTPS read-only and does
    /// not publish an MQTT command or follow storage URLs in a response.
    public func history(device: RobotDevice, page: Int) async throws -> [CloudCleaningRecord] {
        try begin(); defer { busy = false }
        try validate(device)
        guard (1...100).contains(page) else { throw ConnectorError.invalid("History page is outside its supported range.") }
        let current = generation, access = try await accessToken(generation)
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "status", value: "0"),
            URLQueryItem(name: "deviceId", value: device.id), URLQueryItem(name: "productId", value: device.productKey)]
        let data = try await request(path: "/sweeper-map-scheme-app-server/v2/work_record/all?" + (query.percentEncodedQuery ?? ""),
                                     method: "GET", token: access.token)
        try check(current)
        return try NarwalHistoryCodec.records(data, device: device)
    }
    public func historicalRoute(device: RobotDevice, record: CloudCleaningRecord) async throws -> CleaningRun {
        try begin(); defer { busy = false }
        try validate(device)
        guard record.productKey == device.productKey, record.deviceID == device.id,
              let recordID = Int64(record.id), recordID > 0, String(recordID) == record.id else {
            throw ConnectorError.invalid("This cleaning record belongs to a different robot or is no longer recognized.")
        }
        let current = generation, access = try await accessToken(generation)
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "clean_record_id", value: record.id),
            URLQueryItem(name: "product_id", value: device.productKey), URLQueryItem(name: "device_id", value: device.id)]
        let data = try await request(path: "/clean-record-app-server/v1/clean-record/detail?" + (query.percentEncodedQuery ?? ""),
                                     method: "GET", token: access.token)
        try check(current)
        return try NarwalHistoryCodec.detail(data, record: record, device: device)
    }
    public func editableMapSnapshot(device: RobotDevice, mapID: Int) async throws -> MapSnapshot {
        try begin(); defer { busy = false }
        return try await readEditableMap(device: device, mapID: mapID)
    }
    /// Only an explicit caller invokes this mutation. The caller must compare
    /// the returned geometry with its reviewed plan before reporting success.
    public func applyRoomOperations(device: RobotDevice, baseline: MapSnapshot, operations: [RoomMapOperation]) async throws -> MapEditCommitResult {
        stopLiveTelemetry()
        try begin(); defer { busy = false }
        try validate(device)
        guard device.canControl, baseline.matches(device: device, mapID: baseline.mapID) else { throw ConnectorError.invalid("The room edit does not belong to this Freo X Ultra.") }
        let current = generation
        let fresh = try await readEditableMap(device: device, mapID: baseline.mapID)
        try MapEditTransaction.validate(current: fresh, baseline: baseline)
        let access = try await accessToken(current)
        let payload = try NarwalCodec.roomOperationRequest(uuid: access.uuid, baseline: fresh, operations: operations)
        let preserved = try MapSnapshotStore.preserve(fresh)
        try check(current)
        rooms.removeValue(forKey: device.id)
        do {
            return try await MapEditTransaction.commit(baseline: fresh, preservedSnapshotURL: preserved, send: {
                try await self.exchange(device: device, access: access, topic: "map/operation", payload: payload, isCommand: true, generation: current)
            }, readBack: {
                try self.check(current)
                return try await self.readEditableMap(device: device, mapID: fresh.mapID)
            }, preserveReadback: {
                _ = try MapSnapshotStore.preserveReadback($0)
            })
        } catch {
            try? MapSnapshotStore.preserveFailure(snapshotURL: preserved, operations: operations, error: error)
            throw error
        }
    }
    private func readEditableMap(device: RobotDevice, mapID: Int) async throws -> MapSnapshot {
        try validate(device); let current = generation
        let access = try await accessToken(current)
        let request = try NarwalCodec.editableMapRequest(uuid: access.uuid, mapID: mapID)
        let raw = try await exchange(device: device, access: access, topic: "map/get_editable_map", payload: request, isCommand: false, generation: current)
        try check(current)
        let snapshot = try NarwalCodec.editableMapSnapshot(raw, device: device, mapID: mapID)
        rooms[device.id] = CachedRooms(map: RoomMap(mapID: snapshot.mapID, rooms: snapshot.floorplan.rooms, mapRevision: snapshot.editVersion), expires: Date().addingTimeInterval(900))
        return snapshot
    }
    public func plan(device: RobotDevice) async throws -> CleaningTaskSnapshot {
        try begin(); defer { busy = false }
        return try NarwalCodec.plan(try await query(device, topic: "clean/current_clean_task/get"))
    }
    public func sweepIntensitySupport(device: RobotDevice) async throws -> Bool? {
        try begin(); defer { busy = false }
        return try NarwalCodec.sweepIntensitySupport(try await query(device, topic: "common/get_feature_list"))
    }
    public func command(device: RobotDevice, action: RobotAction, mode: CleaningMode, roomIDs: [Int], options: CleaningOptions = .standard) async throws -> CommandAcknowledgement {
        try begin(); defer { busy = false }
        try validate(device)
        guard device.canControl else { throw ConnectorError.invalid("This robot model is available for reading only.") }
        var mapID: Int?
        if action == .start {
            guard let cached = rooms[device.id], cached.expires > Date(), let actualID = cached.map.mapID, actualID > 0 else { throw ConnectorError.invalid("Load this robot's current rooms before starting a clean.") }
            let known = Set(cached.map.rooms.map(\.id))
            guard !roomIDs.isEmpty, roomIDs.count <= 100, Set(roomIDs).count == roomIDs.count, roomIDs.allSatisfy(known.contains) else { throw ConnectorError.invalid("Select rooms returned by this robot.") }
            mapID = actualID
        }
        let current = generation
        let access = try await accessToken(current)
        let command = try NarwalCodec.command(uuid: access.uuid, action: action, mode: mode, roomIDs: roomIDs, mapID: mapID, options: options)
        let raw = try await exchange(device: device, access: access, topic: command.topic, payload: command.payload, isCommand: true, generation: current)
        // Receiving an unparseable response does not mean the robot stayed idle.
        do { return try NarwalCodec.acknowledgement(raw) }
        catch { throw ConnectorError.outcomeUnknown }
    }
    func begin() throws {
        guard !busy else { throw ConnectorError.invalid("Another request is running. Wait for its result before trying again.") }
        busy = true
    }
    private func clear() {
        stopLiveTelemetry(); scheduleUncertainDevices = []
        generation += 1; session = nil; pendingRestoration = nil; rememberSession = false; devices = []; rooms = [:]
        expiryTask?.cancel(); expiryTask = nil; exchangeTask?.cancel(); exchangeTask = nil; httpTask?.cancel(); httpTask = nil
    }
    private func expire(generation expected: Int) { if generation == expected { clear(); try? vault.remove() } }
    private func scheduleExpiry(_ current: Int) {
        expiryTask?.cancel()
        guard let access = session ?? pendingRestoration, access.expires != .distantFuture else { return }
        let remaining = max(0, access.expires.timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expire(generation: current)
        }
    }
    private func requireUnexpiredSession() throws {
        guard let access = session, access.expires > now() else {
            clear(); try? vault.remove(); throw SessionRestoreFailure.expired
        }
    }
    func check(_ expected: Int) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw ConnectorError.invalid("The session was disconnected.") }
    }
    func validate(_ device: RobotDevice) throws {
        try requireUnexpiredSession()
        guard devices.contains(device) else { throw ConnectorError.invalid("Choose a robot discovered on this account.") }
    }
    func accessToken(_ expected: Int) async throws -> Session {
        try check(expected); try requireUnexpiredSession()
        guard let access = session else { throw SessionRestoreFailure.expired }
        if access.tokenExpires.timeIntervalSince(now()) > 60 { return access }
        guard let refresh = access.refresh else { clear(); try? vault.remove(); throw SessionRestoreFailure.expired }
        do {
            let response = try await request(path: "/user-authentication-server/v1/token/refresh", method: "POST", body: ["refreshToken": refresh])
            try check(expected); try requireUnexpiredSession()
            try Self.checkAccountResponse(response)
            let renewed: Session
            do { renewed = try Self.decodeSession(response, now: now()) }
            catch { throw SessionRestoreFailure.invalidIdentity }
            guard renewed.uuid == access.uuid else { throw SessionRestoreFailure.invalidIdentity }
            let next = Session(issuedAt: access.issuedAt, uuid: renewed.uuid, token: renewed.token,
                refresh: renewed.refresh ?? refresh, tokenExpires: renewed.tokenExpires, expires: access.expires)
            session = next
            if rememberSession {
                do { try vault.save(try Self.savedSessionData(next)) }
                catch {
                    rememberSession = false; try? vault.remove()
                    throw SessionStorageFailure()
                }
            }
            return next
        } catch {
            if expected == generation, Self.invalidatesSavedSession(error) { clear(); try? vault.remove() }
            throw error
        }
    }
    func request(path: String, method: String, body: [String: String]? = nil, token: String? = nil) async throws -> Data {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await requestData(path: path, method: method, body: data, token: token)
    }
    func requestData(path: String, method: String, body data: Data? = nil, token: String? = nil) async throws -> Data {
        let current = generation
        let destination = try await policy.destination(.https)
        var headers = ["Accept": "application/json"]
        if let token { headers["Auth-Token"] = token }
        if data != nil { headers["Content-Type"] = "application/json" }
        let outgoingHeaders = headers
        let client = http
        let pending = Task {
            try await self.httpPreflight(generation: current)
            return try await client(destination, method, path, outgoingHeaders, data,
                                    { try await self.httpPreflight(generation: current) })
        }
        httpTask = pending; defer { httpTask = nil }
        do { return try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() } }
        catch {
            if current == generation, let failure = error as? AccountHTTPError, failure.rejectsAuthentication {
                clear(); try? vault.remove()
            }
            throw error
        }
    }
    private func httpPreflight(generation current: Int) async throws {
        try check(current); _ = try await policy.destination(.https); try check(current)
        if let access = session, access.expires <= now() { clear(); try? vault.remove(); throw SessionRestoreFailure.expired }
    }
    func query(_ device: RobotDevice, topic: String) async throws -> Data {
        try validate(device); let current = generation
        let access = try await accessToken(current)
        return try await exchange(device: device, access: access, topic: topic, payload: NarwalCodec.identity(uuid: access.uuid), isCommand: false, generation: current)
    }
    private func exchange(device: RobotDevice, access: Session, topic: String, payload: Data, isCommand: Bool, generation current: Int) async throws -> Data {
        let destination = try await policy.destination(.mqtt)
        let correlation = try NarwalCodec.correlation(id: UUID().uuidString.lowercased(), timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
        try check(current)
        let fullTopic = Self.mqttTopic(device: device, suffix: topic)
        let pending = Task { try await NarwalMQTT.exchange(destination: destination, uuid: access.uuid, token: access.token, device: device, topic: fullTopic, payload: payload, correlation: correlation, isCommand: isCommand, preflight: { try await self.preflight(device: device, topic: topic, generation: current) }) }
        exchangeTask = pending; defer { exchangeTask = nil }
        do {
            let reply = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
            do { try check(current) }
            catch { if isCommand { throw ConnectorError.outcomeUnknown }; throw error }
            return reply
        } catch { if isCommand, current != generation { throw ConnectorError.outcomeUnknown }; throw error }
    }
    /// Service operations name a suffix; MQTT uses the selected device's full
    /// namespace. MQTTSession remains the authority for identifiers and actions.
    nonisolated static func mqttTopic(device: RobotDevice, suffix: String) -> String {
        "/\(device.productKey)/\(device.id)/\(suffix)"
    }
    private func preflight(device: RobotDevice, topic: String, generation current: Int) async throws {
        try check(current); try validate(device)
        _ = try await policy.destination(.mqtt)
        try check(current); try validate(device)
        if topic == "clean/start_clean" {
            guard let cached = rooms[device.id], cached.expires > Date(), (cached.map.mapID ?? 0) > 0 else { throw ConnectorError.invalid("The saved rooms expired while connecting. Reload rooms before starting.") }
        }
    }
    static func decodeSession(_ data: Data, now: Date = Date(), allowExpiredToken: Bool = false) throws -> Session {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.invalid("Narwal returned an unrecognized login response.")
        }
        guard successCode(root["code"]) else {
            throw ConnectorError.invalid(AccountFailureDetails.message(in: root,
                fallback: "Narwal did not accept this login. Use your Narwal email and separate Narwal password."))
        }
        guard let result = root["result"] as? [String: Any],
              let token = result["token"] as? String, validToken(token) else {
            throw ConnectorError.invalid("Narwal accepted the request but did not return a usable sign-in.")
        }
        let pieces = token.split(separator: ".")
        var claims: [String: Any] = [:]
        if pieces.count > 1 {
            var base64 = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let raw = Data(base64Encoded: base64), let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw ConnectorError.invalid("The returned account token was not recognized.") }
            claims = object
        }
        guard let uuid = (result["uuid"] ?? claims["uuid"]) as? String, validUUID(uuid) else { throw ConnectorError.invalid("The account identifier was not recognized.") }
        if let tokenUUID = claims["uuid"] { guard let value = tokenUUID as? String, value == uuid else { throw ConnectorError.invalid("The returned account identities do not match.") } }
        let candidate = (result["refresh_token"] ?? result["refreshToken"]) as? String
        let refresh = candidate.flatMap { validToken($0) ? $0 : nil }
        // Narwal tokens may omit the optional JWT exp claim. Match the browser
        // connector's one-hour refresh schedule in that case. This is only a
        // local deadline: Narwal still authenticates the token on discovery.
        var expiration = now.addingTimeInterval(3600)
        if let claim = claims["exp"] {
            guard let value = claim as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue else { throw ConnectorError.invalid("Narwal returned an unrecognized token expiration value.") }
            guard allowExpiredToken || value.doubleValue > now.timeIntervalSince1970 else { throw ConnectorError.invalid("Narwal returned an expired account token. Check the iPhone's date and time, then sign in again.") }
            expiration = Date(timeIntervalSince1970: value.doubleValue)
        }
        return Session(issuedAt: now, uuid: uuid, token: token, refresh: refresh, tokenExpires: expiration, expires: refresh == nil ? min(expiration, now.addingTimeInterval(8 * 3600)) : .distantFuture)
    }
    private struct SavedSession: Codable {
        let version: Int
        let region: String
        let session: Session
    }
    static func savedSessionData(_ session: Session) throws -> Data {
        try JSONEncoder().encode(SavedSession(version: 1, region: "US", session: session))
    }
    static func decodeSavedSession(_ data: Data, now: Date) throws -> Session {
        guard data.count <= 65536 else { throw SessionRestoreFailure.invalidIdentity }
        let envelope: SavedSession
        do { envelope = try JSONDecoder().decode(SavedSession.self, from: data) }
        catch { throw SessionRestoreFailure.invalidIdentity }
        let saved = envelope.session
        guard envelope.version == 1, envelope.region == "US",
              saved.issuedAt.timeIntervalSince1970.isFinite,
              saved.expires.timeIntervalSince1970.isFinite,
              saved.tokenExpires.timeIntervalSince1970.isFinite,
              saved.issuedAt <= now, saved.expires > saved.issuedAt,
              (saved.expires == .distantFuture ? saved.refresh != nil :
                  saved.expires.timeIntervalSince(saved.issuedAt) <= 8 * 3600),
              validUUID(saved.uuid), validToken(saved.token),
              saved.refresh.map(validToken) ?? true else { throw SessionRestoreFailure.invalidIdentity }
        guard saved.refresh != nil || min(saved.expires, saved.tokenExpires) > now else { throw SessionRestoreFailure.expired }
        let synthetic = try JSONSerialization.data(withJSONObject: ["code": 0,
            "result": ["uuid": saved.uuid, "token": saved.token]])
        // Decode identity and token syntax without resetting either saved deadline.
        do {
            let checked = try decodeSession(synthetic, now: saved.issuedAt, allowExpiredToken: true)
            // For JWTs with exp, the saved refresh deadline cannot exceed the claim.
            let pieces = saved.token.split(separator: ".")
            if pieces.count > 1 {
                var value = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                value += String(repeating: "=", count: (4 - value.count % 4) % 4)
                if let raw = Data(base64Encoded: value),
                   let claims = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                   claims["exp"] != nil, saved.tokenExpires > checked.tokenExpires {
                    throw SessionRestoreFailure.invalidIdentity
                }
            }
        } catch { throw SessionRestoreFailure.invalidIdentity }
        return Session(issuedAt: saved.issuedAt, uuid: saved.uuid, token: saved.token,
                       refresh: saved.refresh, tokenExpires: saved.tokenExpires,
                       expires: saved.refresh == nil ? min(saved.expires, saved.tokenExpires) : .distantFuture)
    }
    private static func checkAccountResponse(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID() else {
            throw ConnectorError.invalid("Narwal returned an unrecognized account response. Retry saved sign-in.")
        }
        guard code.doubleValue == 0 else {
            // Undocumented application error codes are not assumed to mean an
            // invalid credential. Preserve the original deadline for explicit retry.
            throw ConnectorError.invalid(AccountFailureDetails.message(in: root,
                fallback: "Narwal could not verify this saved sign-in. Retry later or sign in again."))
        }
    }
    private static func invalidatesSavedSession(_ error: Error) -> Bool {
        error is SessionRestoreFailure || (error as? AccountHTTPError)?.rejectsAuthentication == true
    }
    private static func validToken(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 16384 && !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 } }
    private static func fullMatch(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex }
    private static func validUUID(_ value: String) -> Bool { [32,36].contains(value.utf8.count) && fullMatch(value, "^(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})$") }
    private static func successCode(_ value: Any?) -> Bool { guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }; return number.doubleValue == 0 }
    static func decodeDevices(_ data: Data) throws -> [RobotDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.invalid("Narwal returned an unrecognized device response.")
        }
        guard successCode(root["code"]) else {
            throw ConnectorError.invalid(AccountFailureDetails.message(in: root,
                fallback: "Narwal did not accept device discovery."))
        }
        let nested = root["result"] as? [String: Any]
        guard let list = (root["result"] as? [Any]) ?? (nested?["deviceInfoList"] as? [Any]), list.count <= 100 else { throw ConnectorError.invalid("Device discovery returned an unrecognized list.") }
        var devices: [RobotDevice] = []; var seen = Set<String>()
        func text(_ value: Any?, limit: Int) throws -> String? {
            guard let value, !(value is NSNull) else { return nil }
            guard let string = value as? String else { throw ConnectorError.invalid("The device metadata was not recognized.") }
            let safe = string.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return safe.isEmpty ? nil : String(safe.prefix(limit))
        }
        for raw in list {
            guard let item = raw as? [String: Any], let id = item["deviceId"] as? String, id.utf8.count == 32, fullMatch(id, "^[a-fA-F0-9]{32}$"), let product = item["productId"] as? String, product.utf8.count <= 32, fullMatch(product, "^[a-zA-Z0-9]{1,32}$") else { throw ConnectorError.invalid("A device lacks valid messaging identifiers.") }
            guard seen.insert(product + ":" + id).inserted else { continue }
            let name = try text(item["robotName"], limit: 128) ?? "Narwal robot"
            let firmware = try text(item["firmwareVersion"], limit: 64)
            let serial = try text(item["snNumber"], limit: 256)
            devices.append(RobotDevice(id: id, productKey: product, name: name, firmware: firmware, serialSuffix: serial.map { String($0.suffix(4)) }))
        }
        return devices
    }
}
