import XCTest
import Foundation
@testable import FreoCore

final class ServiceTests: XCTestCase {
    private let identifier = String(repeating: "a", count: 32)
    private var device: [String: Any] {
        ["deviceId": identifier, "productId": "EHf6cRNRGT", "robotName": " Daily\nclean\u{7f} ",
         "firmwareVersion": "v01.09.01.00", "snNumber": "PRIVATE-SERIAL-1234",
         "uuid": "PRIVATE-ACCOUNT", "email": "PRIVATE-EMAIL", "token": "PRIVATE-TOKEN",
         "refreshToken": "PRIVATE-REFRESH", "localKey": "PRIVATE-KEY", "deviceSecret": "PRIVATE-SECRET"]
    }
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func token(_ claims: Any) throws -> String {
        let encoded = try data(claims).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30." + encoded + ".offline-signature"
    }

    func testSessionDecodingAcceptsFutureClaimsAndBothRefreshTokenKeys() throws {
        let expiration = floor(Date().timeIntervalSince1970) + 3600
        let access = try token(["uuid": identifier, "exp": expiration])
        for refreshKey in ["refresh_token", "refreshToken"] {
            let session = try NarwalService.decodeSession(data(["code": 0, "result": ["token": access, refreshKey: "offline-refresh"]]))
            XCTAssertEqual(session.uuid, identifier)
            XCTAssertEqual(session.token, access)
            XCTAssertEqual(session.refresh, "offline-refresh")
            XCTAssertEqual(session.tokenExpires.timeIntervalSince1970, expiration, accuracy: 0.01)
            XCTAssertEqual(session.expires, .distantFuture)
        }
    }

    func testSessionWithNoJWTExpirationUsesBoundedLocalDeadlines() throws {
        let access = try token(["uuid": identifier])
        let before = Date()
        let session = try NarwalService.decodeSession(data(["code": 0, "result": ["token": access, "refresh_token": "offline-refresh"]]))
        XCTAssertEqual(session.uuid, identifier)
        XCTAssertEqual(session.token, access)
        XCTAssertEqual(session.refresh, "offline-refresh")
        XCTAssertGreaterThanOrEqual(session.tokenExpires.timeIntervalSince(before), 3600)
        XCTAssertLessThan(session.tokenExpires.timeIntervalSince(before), 3605)
        XCTAssertEqual(session.expires, .distantFuture)

        // An explicit account ID remains valid even when a JWT has no uuid claim.
        let identified = try NarwalService.decodeSession(data(["code": 0, "result": ["uuid": identifier, "token": try token(["scope": "app"])]]))
        XCTAssertEqual(identified.uuid, identifier)
        XCTAssertLessThanOrEqual(identified.tokenExpires.timeIntervalSinceNow, 3600)
        // Omitting both identity sources must still fail.
        XCTAssertThrowsError(try NarwalService.decodeSession(data(["code": 0, "result": ["token": try token(["scope": "app"])]])))
    }

    func testSessionRejectsExpiredInvalidOrMalformedJWTExpiration() throws {
        let future = floor(Date().timeIntervalSince1970) + 3600
        for expiration: Any in [false, true, "tomorrow", NSNull(), 0, -1, 1, future + 0.5] {
            let access = try token(["uuid": identifier, "exp": expiration])
            XCTAssertThrowsError(try NarwalService.decodeSession(data(["code": 0, "result": ["uuid": identifier, "token": access]])), "expiration: \(expiration)")
        }
        for access in [try token([1, 2, 3]), "header.!invalid.signature"] {
            XCTAssertThrowsError(try NarwalService.decodeSession(data(["code": 0, "result": ["uuid": identifier, "token": access]])))
        }
    }

    func testSessionRejectsIdentityConflictsBooleanSuccessAndUnsafeTokens() throws {
        let access = try token(["uuid": identifier, "exp": floor(Date().timeIntervalSince1970) + 3600])
        for uuid: Any in [String(repeating: "b", count: 32), identifier + "\n", "invalid", 123, NSNull()] {
            XCTAssertThrowsError(try NarwalService.decodeSession(data(["code": 0, "result": ["uuid": uuid, "token": access]])))
        }
        for code: Any in [false, true, "0", 1, NSNull()] {
            XCTAssertThrowsError(try NarwalService.decodeSession(data(["code": code, "result": ["uuid": identifier, "token": access]])))
        }
        for value: Any in ["", "token with space", "token\r\nHeader: value", String(repeating: "a", count: 16385), 123, NSNull()] {
            XCTAssertThrowsError(try NarwalService.decodeSession(data(["code": 0, "result": ["uuid": identifier, "token": value]])))
        }
        let opaque = try NarwalService.decodeSession(data(["code": 0, "result": ["uuid": identifier, "token": "offline-opaque-token"]]))
        XCTAssertGreaterThan(opaque.tokenExpires.timeIntervalSinceNow, 3590)
        XCTAssertLessThanOrEqual(opaque.tokenExpires.timeIntervalSinceNow, 3600)
    }

    func testSessionErrorShowsSanitizedNarwalNetworkRejection() throws {
        let reply = try data(["code": 4031, "message": "IP address not recognized\nplease try again"])
        XCTAssertThrowsError(try NarwalService.decodeSession(reply)) { error in
            XCTAssertTrue(error.localizedDescription.contains("IP address not recognized please try again"))
            XCTAssertFalse(error.localizedDescription.contains("\n"))
        }
        XCTAssertEqual(AccountFailureDetails.message(in: ["code": 4031, "message": "token: private"],
            fallback: "fallback"), "Narwal rejected the request (code 4031). fallback")
    }

    func testDiscoveryAcceptsDocumentedContainersAndReturnsOnlySafeDeviceMetadata() throws {
        for result: Any in [[device], ["deviceInfoList": [device]]] {
            let found = try NarwalService.decodeDevices(data(["code": 0, "result": result]))
            XCTAssertEqual(found.count, 1)
            let robot = try XCTUnwrap(found.first)
            XCTAssertEqual(robot.id, identifier)
            XCTAssertEqual(robot.productKey, "EHf6cRNRGT")
            XCTAssertEqual(robot.name, "Daily clean")
            XCTAssertEqual(robot.firmware, "v01.09.01.00")
            XCTAssertEqual(robot.serialSuffix, "1234")
            XCTAssertTrue(robot.canControl)
            XCTAssertFalse(String(reflecting: robot).contains("PRIVATE"))
        }
    }

    func testDiscoveryRequiresANumericSuccessCodeAndRecognizedListShape() throws {
        for code: Any in [false, true, "0", 0.25, -1, 1, NSNull()] {
            XCTAssertThrowsError(try NarwalService.decodeDevices(data(["code": code, "result": [device]])), "code: \(code)")
        }
        for object: Any in [[], ["result": [device]], ["code": 0], ["code": 0, "result": NSNull()], ["code": 0, "result": [:]], ["code": 0, "result": ["devices": [device]]], ["code": 0, "result": [false]]] {
            XCTAssertThrowsError(try NarwalService.decodeDevices(data(object)))
        }
        XCTAssertThrowsError(try NarwalService.decodeDevices(Data("{broken json".utf8)))
        XCTAssertEqual(try NarwalService.decodeDevices(data(["code": 0, "result": []])).count, 0)
    }

    func testDiscoveryRejectsMalformedIdentifiersBeforeTheyCanBecomeTopics() throws {
        for id: Any in [1, NSNull(), "", "other", identifier + "\n", String(repeating: "a", count: 31), String(repeating: "a", count: 33), identifier.replacingOccurrences(of: "a", with: "g")] {
            var item = device; item["deviceId"] = id
            XCTAssertThrowsError(try NarwalService.decodeDevices(data(["code": 0, "result": [item]])), "id: \(id)")
        }
        for product: Any in [1, "", "EHf6cRNRGT\n", "EHf6cRNRGT/response", "../task/pause", "+", "#", String(repeating: "x", count: 33)] {
            var item = device; item["productId"] = product
            XCTAssertThrowsError(try NarwalService.decodeDevices(data(["code": 0, "result": [item]])), "product: \(product)")
        }
    }

    func testDiscoveryBoundsMetadataDeduplicatesAndKeepsUnsupportedModelsReadOnly() throws {
        var long = device
        long["robotName"] = String(repeating: "r", count: 200)
        long["firmwareVersion"] = String(repeating: "v", count: 100)
        long["productId"] = "OtherProduct"
        let result = try NarwalService.decodeDevices(data(["code": 0, "result": [long, long]]))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name.count, 128)
        XCTAssertEqual(result[0].firmware?.count, 64)
        XCTAssertFalse(result[0].canControl)
        var unnamed = device; unnamed.removeValue(forKey: "robotName"); unnamed["firmwareVersion"] = NSNull(); unnamed.removeValue(forKey: "snNumber")
        let fallback = try NarwalService.decodeDevices(data(["code": 0, "result": [unnamed]]))[0]
        XCTAssertEqual(fallback.name, "Narwal robot")
        XCTAssertNil(fallback.firmware)
        XCTAssertNil(fallback.serialSuffix)
        for key in ["robotName", "firmwareVersion", "snNumber"] {
            var invalid = device; invalid[key] = 123
            XCTAssertThrowsError(try NarwalService.decodeDevices(data(["code": 0, "result": [invalid]])))
        }
        XCTAssertThrowsError(try NarwalService.decodeDevices(data(["code": 0, "result": Array(repeating: device, count: 101)])))
    }

    func testPublicIPv4RejectsReservedRangesAtTheirBoundaries() {
        for ip in ["0.255.255.255", "10.255.255.255", "100.64.0.0", "100.127.255.255", "127.255.255.255", "169.254.255.255", "172.16.0.0", "172.31.255.255", "192.0.0.255", "192.88.99.255", "192.168.255.255", "198.18.0.0", "198.19.255.255", "224.0.0.0", "239.255.255.255", "240.0.0.0", "255.255.255.255", "1.1.1.+1", "1.1.1.01", "1.1.1.1\n"] {
            XCTAssertFalse(USNetworkPolicy.isPublicIPv4(ip), ip)
        }
        for ip in ["1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.0", "172.15.255.255", "172.32.0.0", "198.17.255.255", "198.20.0.0", "223.255.255.255"] {
            XCTAssertTrue(USNetworkPolicy.isPublicIPv4(ip), ip)
        }
    }
}
