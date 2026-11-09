import XCTest
@testable import FreoCore

final class CleaningDiagnosticsTests: XCTestCase {
    private func frame(_ bytes: [UInt8]) -> Data {
        precondition(bytes.count < 128)
        return Data([1, UInt8(bytes.count)] + bytes)
    }
    private func task(_ parameters: [UInt8]) -> Data {
        // GetCurrentCleanTask.Response: success1, map1, room8, taskType1.
        let item: [UInt8] = [0x0a, 4, 8, 1, 16, 8, 0x12, UInt8(parameters.count)] + parameters
        let body: [UInt8] = [8, 1, 0x12, UInt8(item.count)] + item + [0x28, 1]
        return frame([8, 1, 0x12, UInt8(body.count)] + body)
    }

    func testTaskPreservesIndependentFanAndSweepIntensityReadback() throws {
        // Field2 Quiet, field11 Strong: never replace one with the other.
        let sample = try XCTUnwrap(NarwalCodec.plan(task([8, 2, 16, 1, 0x58, 3])).samples.first)
        XCTAssertEqual(sample.roomID, 8)
        XCTAssertEqual(sample.parameters[2], 1)
        XCTAssertEqual(sample.parameters[11], 3)
        XCTAssertEqual(sample.reportedSettings, ["Vacuum", "Quiet suction", "Strong sweep intensity"])
    }
    func testUnknownOrAbsentSweepIntensityNeverBecomesQuiet() throws {
        let absent = try XCTUnwrap(NarwalCodec.plan(task([16, 1])).samples.first)
        XCTAssertNil(absent.parameters[11])
        XCTAssertEqual(absent.reportedSettings, ["Quiet suction"])
        let unknown = try XCTUnwrap(NarwalCodec.plan(task([0x58, 99])).samples.first)
        XCTAssertEqual(unknown.parameters[11], 99)
        XCTAssertEqual(unknown.reportedSettings, ["Sweep intensity code 99"])
        let unspecified = try XCTUnwrap(NarwalCodec.plan(task([0x58, 0])).samples.first)
        XCTAssertEqual(unspecified.reportedSettings, ["Unspecified sweep intensity"])
    }
    func testSweepIntensityRejectsDuplicateAndMalformedFields() {
        for parameters: [UInt8] in [[0x58, 1, 0x58, 1], [0x5a, 1, 1], [0x58, 0x80],
                                    [0x58, 0x80, 0x80, 0x80, 0x80, 8]] {
            XCTAssertThrowsError(try NarwalCodec.plan(task(parameters)))
        }
    }
    func testDirectFeatureResponseIsNotASuccessDataEnvelope() throws {
        // Field1 supportMultiMap=false, field2 supportMapRotation=true,
        // field113 supportSweepIntensityLevel=true. Field1 is not a result code.
        let direct: [UInt8] = [8, 0, 16, 1, 0x88, 7, 1]
        XCTAssertEqual(try NarwalCodec.sweepIntensitySupport(frame(direct)), true)
        XCTAssertEqual(try NarwalCodec.sweepIntensitySupport(frame([0x88, 7, 0])), false)
        XCTAssertNil(try NarwalCodec.sweepIntensitySupport(frame([8, 1, 16, 1])))
        let identity = try NarwalCodec.identity(uuid: String(repeating: "a", count: 32))
        XCTAssertEqual(try NarwalCodec.sweepIntensitySupport(identity + Data(direct)), true)
    }
    func testFeatureSupportFailsClosedOnWrongWireBooleanAndDuplicates() {
        for fields: [UInt8] in [[0x88, 7, 1, 0x88, 7, 1], [0x88, 7, 2], [0x8a, 7, 0],
                                [8, 2], [8, 1, 0x12, 3, 0x88, 7, 1], [0x88, 7, 0x80]] {
            XCTAssertThrowsError(try NarwalCodec.sweepIntensitySupport(frame(fields)))
        }
        XCTAssertThrowsError(try NarwalCodec.sweepIntensitySupport(Data(repeating: 0, count: 128 * 1024 + 1)))
    }
}
