import XCTest
import Foundation
import Security
@testable import FreoCore

private final class FakeSessionVault: SessionVault, @unchecked Sendable {
    var enabled = false
    var data: Data?
    var saves = 0
    var deletionFails = false
    var readFails = false
    var writeFails = false
    func isEnabled() -> Bool { enabled }
    func load() throws -> Data? {
        guard enabled else { return nil }
        if readFails { throw URLError(.noPermissionsToReadFile) }
        return data
    }
    func save(_ value: Data) throws {
        if writeFails { throw URLError(.cannotWriteToFile) }
        data = value; enabled = true; saves += 1
    }
    func remove() throws {
        enabled = false
        if deletionFails { throw URLError(.noPermissionsToReadFile) }
        data = nil
    }
}
private actor FakeSessionPolicy: SessionNetworkPolicy {
    var expires: Date
    var rechecks = 0
    var checks = 0
    var failRecheck = false
    init(_ expires: Date) { self.expires = expires }
    func expiration() -> Date { expires }
    func destination(_ kind: NarwalServiceKind) throws -> VerifiedDestination {
        checks += 1
        guard expires > Date() else { throw URLError(.cannotConnectToHost) }
        return VerifiedDestination(host: "us-app.narwaltech.com", port: 443, address: "1.1.1.1")
    }
    func recheck() throws -> Date {
        rechecks += 1
        if failRecheck { throw URLError(.notConnectedToInternet) }
        expires = Date().addingTimeInterval(86400); return expires
    }
    func setFailure() { failRecheck = true }
}
private actor FakeSessionHTTP {
    enum Reply { case data(Data), error(Error) }
    var replies: [Reply]
    var paths: [String] = []
    var headers: [[String: String]] = []
    var bodies: [Data?] = []
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    init(_ replies: [Reply]) { self.replies = replies }
    func suspendNext() { hold = true }
    func release() { continuation?.resume(); continuation = nil }
    func send(_ path: String, headers: [String: String], body: Data?) async throws -> Data {
        paths.append(path); self.headers.append(headers); bodies.append(body)
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() { case .data(let data): return data; case .error(let error): throw error }
    }
    func count() -> Int { paths.count }
}

final class SessionPersistenceTests: XCTestCase {
    private let uuid = String(repeating: "a", count: 32)
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func login(uuid: String? = nil, token: String = "synthetic-access", refresh: String = "synthetic-refresh") throws -> Data {
        try json(["code": 0, "result": ["uuid": uuid ?? self.uuid, "token": token, "refreshToken": refresh]])
    }
    private func devices() throws -> Data {
        try json(["code": 0, "result": [["deviceId": String(repeating: "b", count: 32),
            "productId": "EHf6cRNRGT", "robotName": "Synthetic robot"]]])
    }
    private func service(_ vault: FakeSessionVault, _ http: FakeSessionHTTP,
                         policy: FakeSessionPolicy? = nil, now: Date = Date()) -> NarwalService {
        NarwalService(vault: vault, policy: policy ?? FakeSessionPolicy(Date().addingTimeInterval(3600)),
            now: { now }, http: { _, _, path, headers, body, preflight in
                try await preflight()
                return try await http.send(path, headers: headers, body: body)
            })
    }
    private func cached(_ vault: FakeSessionVault, now: Date = Date(), tokenExpires: Date? = nil,
                        expires: Date? = nil) throws -> NarwalService.Session {
        let saved = NarwalService.Session(issuedAt: now.addingTimeInterval(-3600), uuid: uuid,
            token: "synthetic-access", refresh: "synthetic-refresh",
            tokenExpires: tokenExpires ?? now.addingTimeInterval(1800),
            expires: expires ?? now.addingTimeInterval(7 * 3600))
        try vault.save(NarwalService.savedSessionData(saved)); return saved
    }

    func testSignInRechecksExpiredPolicyBeforeSendingCredentials() async throws {
        let vault = FakeSessionVault()
        let policy = FakeSessionPolicy(.distantPast)
        let http = FakeSessionHTTP([.data(try login()), .data(try devices())])
        let connector = service(vault, http, policy: policy)
        _ = try await connector.signIn(email: "fixture@example.invalid", password: "synthetic", rememberSession: true)
        let checks = await policy.rechecks
        XCTAssertEqual(checks, 1)

        let failingPolicy = FakeSessionPolicy(.distantPast)
        await failingPolicy.setFailure()
        let blockedHTTP = FakeSessionHTTP([])
        do {
            _ = try await service(FakeSessionVault(), blockedHTTP, policy: failingPolicy)
                .signIn(email: "fixture@example.invalid", password: "synthetic", rememberSession: true)
            XCTFail("Verification must succeed before login")
        } catch {}
        let calls = await blockedHTTP.count()
        XCTAssertEqual(calls, 0)
    }

    func testSecureStorageFailurePreservesSuccessfulLogin() async throws {
        let vault = FakeSessionVault()
        vault.writeFails = true
        let http = FakeSessionHTTP([.data(try login()), .data(try devices())])
        let connector = service(vault, http)
        do {
            _ = try await connector.signIn(email: "fixture@example.invalid", password: "synthetic", rememberSession: true)
            XCTFail("Expected a storage warning")
        } catch { XCTAssertTrue(error is SessionStorageFailure) }
        let restored = try await connector.restoreSession()
        XCTAssertEqual(restored?.count, 1)
        let calls = await http.count()
        XCTAssertEqual(calls, 2)
        XCTAssertNil(vault.data)
    }

    func testDefaultSignInNeverSavesPasswordOrSession() async throws {
        let vault = FakeSessionVault(), http = FakeSessionHTTP([.data(try login()), .data(try devices())])
        let connector = service(vault, http)
        let result = try await connector.signIn(email: "synthetic@example.invalid", password: "never-persist-this")
        XCTAssertEqual(result.count, 1); XCTAssertNil(vault.data); XCTAssertEqual(vault.saves, 0)
        let remembered = await connector.isSessionRemembered(); XCTAssertFalse(remembered)
    }

    func testOptInPersistsVerifiedSessionWithoutPasswordAndRestoresSameDeadline() async throws {
        let vault = FakeSessionVault(), clock = Date()
        let first = service(vault, FakeSessionHTTP([.data(try login()), .data(try devices())]), now: clock)
        _ = try await first.signIn(email: "synthetic@example.invalid", password: "never-persist-this", rememberSession: true)
        let bytes = try XCTUnwrap(vault.data)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("password"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("never-persist-this"))
        let original = try NarwalService.decodeSavedSession(bytes, now: clock)
        let http = FakeSessionHTTP([.data(try devices())])
        let second = service(vault, http, now: clock.addingTimeInterval(1200))
        let found = try await second.restoreSession(); XCTAssertEqual(found?.count, 1)
        let deadline = await second.sessionExpiration(); XCTAssertEqual(deadline, original.expires)
        let paths = await http.paths
        XCTAssertEqual(paths, ["/user-device-platform-server/device-info/getDeviceInfoList"])
        XCTAssertEqual(vault.saves, 1)
    }

    func testLegacySessionRenewsAfterOriginalEightHourDeadline() async throws {
        let vault = FakeSessionVault(), now = Date()
        let original = try cached(vault, now: now, tokenExpires: now.addingTimeInterval(-1))
        let http = FakeSessionHTTP([.data(try login(token: "new-access", refresh: "new-refresh")), .data(try devices())])
        let later = now.addingTimeInterval(24 * 3600)
        let connector = service(vault, http, now: later)
        _ = try await connector.restoreSession()
        let saved = try NarwalService.decodeSavedSession(XCTUnwrap(vault.data), now: later)
        XCTAssertEqual(saved.expires, .distantFuture); XCTAssertEqual(saved.issuedAt, original.issuedAt)
        XCTAssertEqual(saved.token, "new-access"); XCTAssertEqual(saved.refresh, "new-refresh")
        let sent = await http.headers
        XCTAssertEqual(sent.last?["Auth-Token"], "new-access")
    }

    func testExpiredPolicyRechecksBeforeAnyCredentialAndFailureRetainsCache() async throws {
        let vault = FakeSessionVault(); _ = try cached(vault)
        let policy = FakeSessionPolicy(Date.distantPast), http = FakeSessionHTTP([.data(try devices())])
        await policy.setFailure()
        do { _ = try await service(vault, http, policy: policy).restoreSession(); XCTFail("Expected failed policy") } catch {}
        let calls = await http.count(); XCTAssertEqual(calls, 0); XCTAssertTrue(vault.enabled)
        let successfulPolicy = FakeSessionPolicy(Date.distantPast)
        _ = try await service(vault, http, policy: successfulPolicy).restoreSession()
        let rechecks = await successfulPolicy.rechecks; XCTAssertEqual(rechecks, 1)
        let received = await http.count(); XCTAssertEqual(received, 1)
    }

    func testExpiredCorruptAndExtendedLocalDeadlinesArePurgedWithoutHTTP() async throws {
        for kind in 0...2 {
            let vault = FakeSessionVault(), now = Date(), http = FakeSessionHTTP([])
            if kind == 0 { _ = try cached(vault, now: now, expires: now.addingTimeInterval(-3601)) }
            if kind == 1 { try vault.save(Data("corrupt".utf8)) }
            if kind == 2 { _ = try cached(vault, now: now, expires: now.addingTimeInterval(8 * 3600)) }
            do { _ = try await service(vault, http, now: now).restoreSession(); XCTFail("Expected invalid saved session") } catch {}
            XCTAssertFalse(vault.enabled); XCTAssertNil(vault.data)
            let count = await http.count(); XCTAssertEqual(count, 0)
        }
    }

    func testTransientDiscoveryAndRefreshErrorsRetainEnvelopeForExplicitRetry() async throws {
        for refresh in [false, true] {
            for reply: FakeSessionHTTP.Reply in [.error(URLError(.timedOut)), .error(AccountHTTPError(status: 503)),
                .data(try json(["code": 401])), .data(try json(["code": 500]))] {
                let vault = FakeSessionVault(), now = Date()
                _ = try cached(vault, now: now, tokenExpires: now.addingTimeInterval(refresh ? -1 : 3600))
                let original = vault.data, connector = service(vault, FakeSessionHTTP([reply]), now: now)
                do { _ = try await connector.restoreSession(); XCTFail("Expected transient failure") } catch {}
                XCTAssertEqual(vault.data, original); XCTAssertTrue(vault.enabled)
                let expiry = await connector.sessionExpiration(); XCTAssertNil(expiry)
            }
        }
    }

    func testDefiniteHTTPRejectionAndRefreshIdentityMismatchPurge() async throws {
        for reply: FakeSessionHTTP.Reply in [.error(AccountHTTPError(status: 401)), .error(AccountHTTPError(status: 403)),
            .data(try login(uuid: String(repeating: "c", count: 32)))] {
            let vault = FakeSessionVault(), now = Date()
            _ = try cached(vault, now: now, tokenExpires: now.addingTimeInterval(-1))
            do { _ = try await service(vault, FakeSessionHTTP([reply]), now: now).restoreSession(); XCTFail("Expected rejected account") } catch {}
            XCTAssertNil(vault.data); XCTAssertFalse(vault.enabled)
        }
    }

    func testKeychainLockedDoesNotDeleteOrSendCredentials() async throws {
        let vault = FakeSessionVault(); _ = try cached(vault); vault.readFails = true
        let http = FakeSessionHTTP([])
        do { _ = try await service(vault, http).restoreSession(); XCTFail("Expected locked vault") } catch {}
        XCTAssertTrue(vault.enabled); XCTAssertNotNil(vault.data)
        let calls = await http.count(); XCTAssertEqual(calls, 0)
    }

    func testDisconnectCancelsSuspendedRestorationAndCannotResave() async throws {
        let vault = FakeSessionVault(); _ = try cached(vault)
        let http = FakeSessionHTTP([.data(try devices())]); await http.suspendNext()
        let connector = service(vault, http)
        let pending = Task { try await connector.restoreSession() }
        while await http.count() == 0 { await Task.yield() }
        try await connector.disconnect(); await http.release()
        do { _ = try await pending.value; XCTFail("Disconnected restore must not succeed") } catch {}
        XCTAssertFalse(vault.enabled); XCTAssertNil(vault.data)
        let expiry = await connector.sessionExpiration(); XCTAssertNil(expiry)
    }

    func testRememberToggleHonorsBusyAndCanDisableWithoutSession() async throws {
        let vault = FakeSessionVault(); _ = try cached(vault)
        let http = FakeSessionHTTP([.data(try devices())]); await http.suspendNext()
        let connector = service(vault, http), pending = Task { try await connector.restoreSession() }
        while await http.count() == 0 { await Task.yield() }
        do { try await connector.setSessionRemembered(false); XCTFail("Must not race restore") } catch {}
        await http.release(); _ = try await pending.value
        try await connector.setSessionRemembered(false); XCTAssertFalse(vault.enabled)
        let expiry = await connector.sessionExpiration(); XCTAssertNotNil(expiry)
        try await connector.disconnect()
        try await connector.setSessionRemembered(false)
    }

    func testFailedDeletionDisablesRestoreAndReportsFailure() async throws {
        let vault = FakeSessionVault(); _ = try cached(vault); vault.deletionFails = true
        let connector = service(vault, FakeSessionHTTP([]))
        do { try await connector.disconnect(); XCTFail("Deletion failure must be reported") } catch {}
        XCTAssertFalse(vault.enabled); XCTAssertNotNil(vault.data)
        let restored = try await service(vault, FakeSessionHTTP([])).restoreSession(); XCTAssertNil(restored)
    }

    func testRotatedRefreshStorageFailureCanRetryDiscoveryUsingNewInMemoryToken() async throws {
        let vault = FakeSessionVault(), now = Date()
        _ = try cached(vault, now: now, tokenExpires: now.addingTimeInterval(-1))
        vault.writeFails = true
        let http = FakeSessionHTTP([.data(try login(token: "rotated-access", refresh: "rotated-refresh")),
                                    .error(URLError(.timedOut)), .data(try devices())])
        let connector = service(vault, http, now: now)
        do { _ = try await connector.restoreSession(); XCTFail("Expected storage failure") }
        catch { XCTAssertTrue(error is SessionStorageFailure) }
        XCTAssertFalse(vault.enabled); XCTAssertNil(vault.data)
        let notConnected = await connector.sessionExpiration(); XCTAssertNil(notConnected)
        do { _ = try await connector.restoreSession(); XCTFail("Expected discovery timeout") } catch {}
        let result = try await connector.restoreSession(); XCTAssertEqual(result?.count, 1)
        let expiry = await connector.sessionExpiration(); XCTAssertEqual(expiry, .distantFuture)
        let paths = await http.paths
        XCTAssertEqual(paths.filter { $0.contains("/token/refresh") }.count, 1)
        XCTAssertEqual(paths.filter { $0.contains("getDeviceInfoList") }.count, 2)
        let headers = await http.headers; XCTAssertEqual(headers.last?["Auth-Token"], "rotated-access")
    }

    func testInMemoryRestoreExpiresWithoutRefreshToken() async throws {
        final class Clock: @unchecked Sendable { var date = Date() }
        let clock = Clock(), vault = FakeSessionVault()
        let http = FakeSessionHTTP([.data(try login(refresh: "")), .data(try devices())])
        let connector = NarwalService(vault: vault, policy: FakeSessionPolicy(Date().addingTimeInterval(86400)),
            now: { clock.date }, http: { _, _, path, headers, body, preflight in
                try await preflight(); return try await http.send(path, headers: headers, body: body)
            })
        _ = try await connector.signIn(email: "synthetic@example.invalid", password: "synthetic", rememberSession: true)
        clock.date = clock.date.addingTimeInterval(8 * 3600 + 1)
        do { _ = try await connector.restoreSession(); XCTFail("Expired account must not be returned") } catch {}
        XCTAssertFalse(vault.enabled); XCTAssertNil(vault.data)
        let expiry = await connector.sessionExpiration(); XCTAssertNil(expiry)
        let calls = await http.count(); XCTAssertEqual(calls, 2)
    }

    func testConnectedRefreshKeepsRotatedTokenWhenSecureStorageFails() async throws {
        let now = Date(), vault = FakeSessionVault()
        let claims = try json(["uuid": uuid, "exp": floor(now.timeIntervalSince1970) + 30])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        let http = FakeSessionHTTP([.data(try login(token: "e30.\(claims).signature")), .data(try devices()),
                                   .data(try login(token: "rotated-access", refresh: "rotated-refresh"))])
        let connector = service(vault, http, now: now)
        _ = try await connector.signIn(email: "synthetic@example.invalid", password: "synthetic", rememberSession: true)
        let generation = await connector.generation, originalDeadline = await connector.sessionExpiration()
        vault.writeFails = true
        do { _ = try await connector.accessToken(generation); XCTFail("Expected persistence failure") }
        catch { XCTAssertTrue(error is SessionStorageFailure) }
        let current = try await connector.accessToken(generation)
        XCTAssertEqual(current.token, "rotated-access"); XCTAssertEqual(current.refresh, "rotated-refresh")
        XCTAssertEqual(current.expires, originalDeadline)
        XCTAssertFalse(vault.enabled); XCTAssertNil(vault.data)
        let count = await http.count(); XCTAssertEqual(count, 3)
    }

    func testSavedTokenIdentityAndJWTDeadlineCannotBeAltered() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let claims = try json(["uuid": uuid, "exp": now.addingTimeInterval(3600).timeIntervalSince1970])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        for (identity, deadline) in [(String(repeating: "c", count: 32), now.addingTimeInterval(3600)),
                                    (uuid, now.addingTimeInterval(3601))] {
            let session = NarwalService.Session(issuedAt: now, uuid: identity, token: "e30.\(claims).signature",
                refresh: "refresh", tokenExpires: deadline, expires: now.addingTimeInterval(8 * 3600))
            XCTAssertThrowsError(try NarwalService.decodeSavedSession(NarwalService.savedSessionData(session), now: now))
        }
    }
}

final class KeychainSessionVaultTests: XCTestCase {
    func testDeviceOnlyAttributesDefaultOffAndDeletionTombstone() throws {
        let suite = "FreoSyntheticSessionTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var item: Data? = Data("orphan".utf8), reads = 0, removalStatus = errSecSuccess
        let operations = KeychainSessionVault.Operations(copy: { query in
            reads += 1
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            return (errSecSuccess, item)
        }, update: { query, values in
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.freo.personal.control.us-session.v1")
            XCTAssertEqual(values[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            XCTAssertEqual(values[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertNil(query[kSecAttrAccessGroup as String]); item = values[kSecValueData as String] as? Data
            return errSecSuccess
        }, add: { _ in XCTFail("Update fixture already exists"); return errSecDuplicateItem },
           delete: { _ in if removalStatus == errSecSuccess { item = nil }; return removalStatus })
        let vault = KeychainSessionVault(defaults: defaults, operations: operations)
        XCTAssertNil(try vault.load()); XCTAssertEqual(reads, 0)
        try vault.save(Data("synthetic-session".utf8)); XCTAssertTrue(vault.isEnabled())
        XCTAssertEqual(try vault.load(), item)
        removalStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try vault.remove()); XCTAssertFalse(vault.isEnabled()); XCTAssertNotNil(item)
        let restarted = KeychainSessionVault(defaults: defaults, operations: operations)
        XCTAssertNil(try restarted.load()); XCTAssertEqual(reads, 1)
    }
}
