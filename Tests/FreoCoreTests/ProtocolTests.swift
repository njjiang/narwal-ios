import XCTest
import Foundation
import zlib
@testable import FreoCore

final class ProtocolTests: XCTestCase {
    private let account = String(repeating: "a", count: 32)

    private func hex(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
    private func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        repeat { let low = UInt8(value & 127); value >>= 7; result.append(low | (value > 0 ? 128 : 0)) } while value > 0
        return result
    }
    private func number(_ tag: Int, _ value: UInt64) -> Data { varint(UInt64(tag * 8)) + varint(value) }
    private func bytes(_ tag: Int, _ value: Data) -> Data { varint(UInt64(tag * 8 + 2)) + varint(UInt64(value.count)) + value }
    private func frame(_ value: Data, declared: Int? = nil) -> Data { Data([1]) + varint(UInt64(declared ?? value.count)) + value }
    private func response(_ value: Data, code: UInt64 = 1) -> Data { frame(number(1, code) + bytes(2, value)) }
    private func item(_ id: UInt64, parameters: Data) -> Data {
        bytes(2, bytes(1, number(1, 1) + number(2, id)) + bytes(2, parameters) + number(3, 1))
    }
    private func deflate(_ data: Data) throws -> Data {
        var count = compressBound(uLong(data.count))
        var output = [UInt8](repeating: 0, count: Int(count))
        let code = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &count, source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard code == Z_OK else { throw ConnectorError.invalid("Test compression failed.") }
        return Data(output.prefix(Int(count)))
    }
    private func dimensions(_ width: UInt64 = 3, _ height: UInt64 = 2) -> Data {
        number(1, 17) + number(3, 60) + number(4, width) + number(5, height)
    }

    func testIdentityCorrelationAndNonMovingTaskEncodings() throws {
        let header = try NarwalCodec.identity(uuid: account)
        XCTAssertEqual(header, hex("01440a20") + Data(account.utf8) + hex("1220") + Data(account.utf8))
        let requestID = "00000000-0000-4000-8000-000000000001"
        XCTAssertEqual(try NarwalCodec.correlation(id: requestID, timestamp: 150), hex("0a24") + Data(requestID.utf8) + hex("1800209601"))
        for (action, topic) in [(RobotAction.pause, "task/pause"), (.resume, "task/resume"), (.dock, "supply/recall")] {
            let command = try NarwalCodec.command(uuid: account, action: action, mode: .vacuumMop, roomIDs: [], mapID: nil)
            XCTAssertEqual(command.topic, topic)
            XCTAssertEqual(command.payload, header)
        }
        for invalid in ["", "not-an-account", String(repeating: "f", count: 33), account + "\n"] {
            XCTAssertThrowsError(try NarwalCodec.identity(uuid: invalid))
            XCTAssertThrowsError(try NarwalCodec.correlation(id: invalid, timestamp: 1))
        }
    }

    func testFourCommandsMatchOriginalIndependentEncoderFixtures() throws {
        let expected: [(CleaningMode, String)] = [
            (.vacuum, "0a36081112160a0408011004120c080210021801200228014001180112160a0408011002120c08021002180120022801400118021a002801"),
            (.mop, "0a36081112160a0408011004120c080310021801200230014001180112160a0408011002120c08031002180120023001400118021a002802"),
            (.vacuumMop, "0a36081112160a0408011004120c080410021801200238014001180112160a0408011002120c08041002180120023801400118021a002804"),
            (.vacuumThenMop, "0a3a081112180a0408011004120e0805100218012002280130014001180112180a0408011002120e080510021801200228013001400118021a002803")
        ]
        let header = try NarwalCodec.identity(uuid: account)
        for (mode, fixture) in expected {
            let command = try NarwalCodec.command(uuid: account, action: .start, mode: mode, roomIDs: [4, 2], mapID: 17)
            XCTAssertEqual(command.topic, "clean/start_clean")
            XCTAssertEqual(command.payload, header + hex(fixture))
        }
        for ids in [[], [0], [-1], [1, 1], [Int(UInt32.max)], Array(1...101)] {
            XCTAssertThrowsError(try NarwalCodec.command(uuid: account, action: .start, mode: .vacuum, roomIDs: ids, mapID: 17))
        }
        for mapID in [nil, 0, -1, Int(UInt32.max)] {
            XCTAssertThrowsError(try NarwalCodec.command(uuid: account, action: .start, mode: .vacuum, roomIDs: [1], mapID: mapID))
        }
    }

    func testPublishedOfficialAppTaskCaptureAndUnknownResultSemantics() throws {
        // Official-app fixture published in sjmotew/NarwalIntegration issue #25.
        let command = hex("0a1e080112160a0408011003120c08041004180120033803400218011a002804")
        let snapshot = try NarwalCodec.plan(response(Data(command.dropFirst(2))))
        XCTAssertEqual(snapshot.resultCode, 1)
        XCTAssertEqual(snapshot.mapID, 1)
        XCTAssertEqual(snapshot.taskType, 4)
        XCTAssertEqual(snapshot.optionFields, [:])
        XCTAssertEqual(snapshot.samples.count, 1)
        XCTAssertEqual(snapshot.samples[0].roomID, 3)
        XCTAssertEqual(snapshot.samples[0].parameters, [1:4, 2:4, 3:1, 4:3, 7:3, 8:2])
        for code in [UInt64(0), 2, 3, 99] {
            let missing = try NarwalCodec.plan(frame(number(1, code)))
            XCTAssertEqual(missing.resultCode, Int(code))
            XCTAssertNil(missing.mapID)
            XCTAssertNil(missing.taskType)
            XCTAssertTrue(missing.samples.isEmpty)
        }
    }

    func testNumericTaskOptionsAndRepeatedRoomsArePreservedWithoutPrivateData() throws {
        let options = number(1, 1) + number(19, 0) + bytes(7, Data("private metadata".utf8)) + bytes(8, number(1, 99))
        let task = number(1, 1) + item(4, parameters: number(1, 4) + number(5, 1) + number(6, 1) + number(7, 1))
            + item(5, parameters: number(1, 4)) + bytes(3, options) + bytes(4, Data("private shortcut name".utf8)) + number(5, 6)
        let result = try NarwalCodec.plan(response(task))
        XCTAssertEqual(result.taskType, 6)
        XCTAssertEqual(result.optionFields, [1:1, 19:0])
        XCTAssertEqual(result.samples.map(\.roomID), [4, 5])
        XCTAssertEqual(result.samples[0].parameters, [1:4, 5:1, 6:1, 7:1])
        for option in [number(1, 1) + number(1, 2), number(1, 1) + bytes(1, Data()), hex("0880"), bytes(1, Data(repeating: 0, count: 4097))] {
            XCTAssertThrowsError(try NarwalCodec.plan(response(bytes(3, option))))
        }
        XCTAssertThrowsError(try NarwalCodec.plan(response(item(1, parameters: number(1, 2) + number(1, 4)))))
        let hundred = (1...100).reduce(Data()) { $0 + item(UInt64($1), parameters: number(1, 4)) }
        XCTAssertEqual(try NarwalCodec.plan(response(hundred)).samples.count, 100)
        XCTAssertThrowsError(try NarwalCodec.plan(response(hundred + item(101, parameters: Data()))))
    }

    func testReportedSuctionReadsOnlyTheTopLevelFanLevelScalar() throws {
        for (fixture, code, title) in [("d00101", 1, "Quiet"), ("d00102", 2, "Normal"),
                                     ("d00103", 3, "Strong"), ("d00104", 4, "Max")] {
            let decoded = try NarwalCodec.status(response(hex(fixture)))
            XCTAssertEqual(decoded.reportedSuctionCode, code)
            XCTAssertEqual(decoded.reportedSuction, CleaningSuction(rawValue: code))
            XCTAssertEqual(decoded.reportedSuctionLabel, title)
            XCTAssertNil(decoded.workingCode); XCTAssertNil(decoded.isPaused)
            XCTAssertNil(decoded.stationContactCode)
        }
        let nested = try NarwalCodec.status(response(bytes(3, number(26, 1))))
        XCTAssertNil(nested.reportedSuctionCode)
        XCTAssertNil(RobotStatus.simulated(battery: 100, workingCode: 4).reportedSuctionCode)
    }

    func testReportedSuctionPreservesUnknownCodesWithoutInventingLabels() throws {
        for code: UInt64 in [0, 5, 255, UInt64(Int.max)] {
            let decoded = try NarwalCodec.status(response(number(26, code)))
            XCTAssertEqual(decoded.reportedSuctionCode, Int(code))
            XCTAssertNil(decoded.reportedSuction); XCTAssertNil(decoded.reportedSuctionLabel)
        }
        for data in [Data(), bytes(26, Data([1])), hex("d50101000000"),
                     hex("d1010100000000000000"), number(26, UInt64.max)] {
            let decoded = try NarwalCodec.status(response(data))
            XCTAssertNil(decoded.reportedSuctionCode)
            XCTAssertNil(decoded.reportedSuctionLabel)
        }
    }

    func testReportedSuctionRejectsDuplicateScalarAndMixedWireFields() throws {
        for fields in [number(26, 1) + number(26, 1), number(26, 1) + number(26, 4),
                       number(26, 1) + bytes(26, Data([1]))] {
            XCTAssertThrowsError(try NarwalCodec.status(response(fields)))
        }
    }

    func testStatusBatteryIsFloatAndMissingOrInvalidNumbersRemainUnknown() throws {
        let captured = hex("010d08011209150000c8421a020801")
        let result = try NarwalCodec.status(captured)
        XCTAssertEqual(result.battery, 100)
        XCTAssertEqual(result.workingCode, 1)
        XCTAssertNil(result.isPaused)
        XCTAssertEqual(result.label, "Standby")
        for bitString in ["0000c07f", "0000807f", "000080bf", "0000ca42"] {
            XCTAssertNil(try NarwalCodec.status(response(hex("15" + bitString))).battery)
        }
        let missing = try NarwalCodec.status(response(Data()))
        XCTAssertNil(missing.battery)
        XCTAssertNil(missing.workingCode)
        XCTAssertNil(missing.isPaused)
        XCTAssertEqual(missing.label, "Unavailable")
        XCTAssertThrowsError(try NarwalCodec.status(response(Data(), code: 2)))
        XCTAssertThrowsError(try NarwalCodec.status(response(hex("150000c842150000c842"))))
    }

    func testLiveStatusDoesNotInferPauseDockOrCompletionFromAmbiguousCode() throws {
        // Published schema and observed firmware disagree on these values.
        // Keep the raw value visible without asserting a physical transition.
        for code: UInt64 in [0, 2, 3, 4, 5, 6, 7, 10, 14, 19, 99, 12345] {
            let status = try NarwalCodec.status(response(bytes(3, number(1, code))))
            XCTAssertEqual(status.workingCode, Int(code))
            XCTAssertNil(status.isPaused)
            XCTAssertEqual(status.label, "State \(code)")
        }
        let paused = try NarwalCodec.status(response(bytes(3, number(1, 4) + number(2, 1))))
        XCTAssertEqual(paused.isPaused, true)
        XCTAssertEqual(paused.workingCode, 4)
        XCTAssertEqual(paused.label, "Paused")
        let explicitOnly = try NarwalCodec.status(response(bytes(3, number(2, 1))))
        XCTAssertNil(explicitOnly.workingCode)
        XCTAssertEqual(explicitOnly.label, "Paused")
        let resumed = try NarwalCodec.status(response(bytes(3, number(1, 2) + number(2, 0))))
        XCTAssertEqual(resumed.isPaused, false)
        XCTAssertEqual(resumed.label, "State 2")
        for flag in [number(2, 2), number(2, UInt64.max), bytes(2, number(1, 1))] {
            let unknown = try NarwalCodec.status(response(bytes(3, number(1, 2) + flag)))
            XCTAssertNil(unknown.isPaused)
            XCTAssertEqual(unknown.label, "State 2")
        }
        for fields in [number(2, 0) + number(2, 1), number(2, 1) + bytes(2, Data()), number(1, 1) + number(1, 2)] {
            XCTAssertThrowsError(try NarwalCodec.status(response(bytes(3, fields))))
        }
    }

    func testSimulatedStatusLabelsAreIsolatedFromLiveStatus() {
        let date = Date(timeIntervalSince1970: 100)
        for (code, label) in [(2, "Paused"), (4, "Cleaning"), (6, "Returning"), (10, "Docked")] {
            let simulated = RobotStatus.simulated(battery: 92, workingCode: code, updatedAt: date)
            XCTAssertEqual(simulated.label, label)
            XCTAssertEqual(simulated.battery, 92)
            XCTAssertEqual(simulated.updatedAt, date)
            XCTAssertEqual(simulated.isPaused, code == 2)
            XCTAssertEqual(RobotStatus(battery: 92, workingCode: code, updatedAt: date).label, "State \(code)")
        }
    }

    func testCompletePrefixAndSeparateIdentityResponseFraming() throws {
        let body = number(1, 1) + bytes(2, hex("150000c8421a020801"))
        XCTAssertEqual(try NarwalCodec.status(frame(body, declared: 2)).battery, 100)
        XCTAssertEqual(try NarwalCodec.status(NarwalCodec.identity(uuid: account) + body).battery, 100)
        for invalid in [Data(), Data([1]), frame(body, declared: 3), frame(body, declared: 999), Data([2, 0]), hex("01ffffffff1000"), frame(hex("08010802")), frame(hex("0b"))] {
            XCTAssertThrowsError(try NarwalCodec.status(invalid))
        }
        let badIdentity = bytes(1, Data(String(repeating: "z", count: 32).utf8)) + bytes(2, Data(account.utf8))
        XCTAssertThrowsError(try NarwalCodec.status(frame(badIdentity + body, declared: badIdentity.count)))
        XCTAssertThrowsError(try NarwalCodec.status(Data(repeating: 0, count: 128 * 1024 + 1)))
        XCTAssertThrowsError(try NarwalCodec.status(frame((0..<257).reduce(Data()) { value, _ in value + number(9, 0) })))
        XCTAssertThrowsError(try NarwalCodec.status(frame(hex("08ffffffffffffffffff02"))))
    }

    func testRoomIdentityNamesAndMapIDAreNeverGuessed() throws {
        let kitchen = bytes(12, number(1, 4) + bytes(3, Data(" Kitchen ".utf8)))
        let unnamed = bytes(12, number(1, 2))
        let result = try NarwalCodec.rooms(response(number(1, 17) + kitchen + unnamed))
        XCTAssertEqual(result.mapID, 17)
        XCTAssertEqual(result.rooms, [RobotRoom(id: 4, name: "Kitchen"), RobotRoom(id: 2, name: "Room 2")])
        XCTAssertNil(try NarwalCodec.rooms(response(kitchen)).mapID)
        for invalid in [
            kitchen + kitchen,
            number(1, 0), number(1, 1) + number(1, 2),
            bytes(12, number(1, 0)), bytes(12, bytes(3, Data("No ID".utf8))),
            bytes(12, number(1, 1) + bytes(3, Data([255]))),
            bytes(12, number(1, 1) + bytes(3, Data("Bad\0name".utf8))),
            bytes(12, number(1, 1) + bytes(3, Data(String(repeating: "x", count: 65).utf8)))
        ] { XCTAssertThrowsError(try NarwalCodec.rooms(response(invalid))) }
        let hundred = (1...100).reduce(Data()) { $0 + bytes(12, number(1, UInt64($1))) }
        XCTAssertEqual(try NarwalCodec.rooms(response(hundred)).rooms.count, 100)
        XCTAssertThrowsError(try NarwalCodec.rooms(response(hundred + bytes(12, number(1, 101)))))
        XCTAssertThrowsError(try NarwalCodec.rooms(Data(repeating: 0, count: 1024 * 1024 + 1)))
    }

    func testRoomTypeLabelsUseAppMappingAndDuplicateInstanceNumbers() throws {
        let records: [(UInt64, UInt64, UInt64, String)] = [
            (71, 4, 1, "Kitchen"), (72, 5, 3, "Bathroom 3"), (73, 6, 0, "Toilet"),
            (74, 8, 1, "Dining room"), (75, 9, 2, "Closet 2"), (76, 10, 1, "Corridor"),
            (77, 11, 1, "Study"), (78, 14, 1, "Storage room"), (79, 0, 2, "Room 2")
        ]
        let map = records.reduce(Data()) { $0 + bytes(12, number(1, $1.0) + number(2, $1.1) + number(8, $1.2)) }
        let result = try NarwalCodec.rooms(response(map))
        XCTAssertEqual(result.rooms, records.map { RobotRoom(id: Int($0.0), name: $0.3) })
    }

    func testCustomRoomNamesTakePrecedenceAndUnknownTypesKeepIDFallback() throws {
        let named = bytes(12, number(1, 31) + number(2, 4) + number(8, 2) + bytes(3, Data("  Cat room  ".utf8)))
        let empty = bytes(12, number(1, 32) + number(2, 3) + bytes(3, Data("   ".utf8)))
        let missing = bytes(12, number(1, 33) + number(8, 9))
        let unknown = bytes(12, number(1, 34) + number(2, 999) + number(8, 2))
        XCTAssertEqual(try NarwalCodec.rooms(response(named + empty + missing + unknown)).rooms, [
            RobotRoom(id: 31, name: "Cat room"), RobotRoom(id: 32, name: "Living room"),
            RobotRoom(id: 33, name: "Room 33"), RobotRoom(id: 34, name: "Room 34")
        ])
    }

    func testMalformedOptionalRoomNamingFieldsAreRejected() throws {
        for tag in [2, 8] {
            for metadata in [number(tag, 0x80000000), bytes(tag, Data("2".utf8)), number(tag, 1) + number(tag, 2)] {
                let room = bytes(12, number(1, 1) + bytes(3, Data("Custom".utf8)) + metadata)
                XCTAssertThrowsError(try NarwalCodec.rooms(response(room)))
            }
        }
    }

    func testZlibAndGzipFloorplansPreserveSourceGridOrder() throws {
        let room = bytes(12, number(1, 1) + bytes(3, Data("Kitchen".utf8)))
        for compressed in [
            hex("789ce3e26450d068609ac0d4c00200093f01f4"),
            hex("1f8b0800000000000013e3e26450d068609ac0d4c002002ff943960b000000")
        ] {
            let result = try NarwalCodec.floorplan(response(dimensions() + room + bytes(17, compressed)))
            XCTAssertEqual(result.mapID, 17)
            XCTAssertEqual(result.width, 3)
            XCTAssertEqual(result.height, 2)
            XCTAssertEqual(result.resolution, 60)
            XCTAssertEqual(result.rooms, [RobotRoom(id: 1, name: "Kitchen")])
            XCTAssertEqual(result.pixels, [0, 32, 40, 256, 272, 512])
        }
        let grid = try deflate(bytes(1, number(4, 0)))
        let noResolution = number(1, 1) + number(4, 2) + number(5, 1) + bytes(17, grid)
        XCTAssertNil(try NarwalCodec.floorplan(response(noResolution)).resolution)
    }

    func testFloorplanRejectsCorruptionDimensionsCountsAndExpansionBombs() throws {
        let valid = hex("789ce3e26450d068609ac0d4c00200093f01f4")
        var corrupt = valid; corrupt[corrupt.count - 1] ^= 255
        for compressed in [Data("bad".utf8), Data(valid.dropLast()), corrupt, valid + Data([0, 1, 2])] {
            XCTAssertThrowsError(try NarwalCodec.floorplan(response(dimensions() + bytes(17, compressed))))
        }
        for dims in [dimensions(0, 2), dimensions(4097, 1), dimensions(1001, 1000), dimensions() + number(4, 3), number(4, 3) + number(5, 2)] {
            XCTAssertThrowsError(try NarwalCodec.floorplan(response(dims + bytes(17, valid))))
        }
        for expanded in [hex("0a00"), hex("0a022020"), hex("120120"), hex("0a012000"), hex("0a028000"), hex("0a05ffffffff10"), hex("0a0100")] {
            let compressed = try deflate(expanded)
            XCTAssertThrowsError(try NarwalCodec.floorplan(response(dimensions(1, 1) + bytes(17, compressed))))
        }
        let bomb = try deflate(Data(repeating: 0, count: 8 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try NarwalCodec.floorplan(response(dimensions(1, 1) + bytes(17, bomb))))
        let maxPixels = try deflate(bytes(1, Data(repeating: 32, count: 1_000_000)))
        XCTAssertEqual(try NarwalCodec.floorplan(response(dimensions(1000, 1000) + bytes(17, maxPixels))).pixels.count, 1_000_000)
    }

    func testAcknowledgementDoesNotTreatRejectionAsCompletion() throws {
        for code in [UInt64(0), 1, 2, 3, 4, 6, 99] {
            let ack = try NarwalCodec.acknowledgement(frame(number(1, code)))
            XCTAssertEqual(ack.resultCode, Int(code))
            XCTAssertEqual(ack.accepted, code == 1)
        }
        for invalid in [frame(Data()), frame(number(1, 1) + number(1, 2)), frame(number(1, 1) + number(2, 1)), frame(number(1, UInt64(UInt32.max)))] {
            XCTAssertThrowsError(try NarwalCodec.acknowledgement(invalid))
        }
    }
}
