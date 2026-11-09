import XCTest
@testable import FreoCore

final class CleaningOptionsTests: XCTestCase {
    private let account = String(repeating: "a", count: 32)
    private func parameters(_ mode: CleaningMode, options: CleaningOptions) throws -> [Int: UInt64] {
        let command = try NarwalCodec.command(uuid: account, action: .start, mode: mode, roomIDs: [7], mapID: 3, options: options)
        let header = try NarwalCodec.identity(uuid: account)
        let outer = try NarwalCodec.fields(Data(command.payload.dropFirst(header.count)))
        let task = try NarwalCodec.fields(NarwalCodec.message(NarwalCodec.one(outer, 1), required: true)!)
        let item = try NarwalCodec.fields(NarwalCodec.message(NarwalCodec.one(task, 2), required: true)!)
        let settings = try NarwalCodec.fields(NarwalCodec.message(NarwalCodec.one(item, 2), required: true)!)
        return Dictionary(uniqueKeysWithValues: settings.map { ($0.tag, $0.integer!) })
    }
    func testCustomOptionsUseCorrectNativeFieldsForEveryMode() throws {
        let options = CleaningOptions(passes: 2, suction: .max, humidity: .wet, route: .intensive)
        for mode in CleaningMode.allCases {
            let value = try parameters(mode, options: options)
            XCTAssertEqual(value[2], 4)
            XCTAssertEqual(value[3], 1) // Scrubbing remains the ordinary preset.
            XCTAssertEqual(value[4], 3)
            XCTAssertEqual(value[8], 2)
            XCTAssertEqual(value[5], [.vacuum, .vacuumThenMop].contains(mode) ? 2 : nil)
            XCTAssertEqual(value[6], [.mop, .vacuumThenMop].contains(mode) ? 2 : nil)
            XCTAssertEqual(value[7], mode == .vacuumMop ? 2 : nil)
            XCTAssertNil(value[9]) // Do not invent Freo Mind or heavy-dirty flags.
        }
    }
    func testUnsupportedCountsNeverBecomeCommands() throws {
        for count in [-1, 0, 3, Int.max] {
            XCTAssertThrowsError(try parameters(.vacuumMop, options: CleaningOptions(passes: count)))
        }
        // Pause/dock/resume are not blocked by an unrelated invalid picker.
        XCTAssertEqual(try NarwalCodec.command(uuid: account, action: .pause, mode: .vacuum,
            roomIDs: [], mapID: nil, options: .init(passes: 0)).payload, try NarwalCodec.identity(uuid: account))
    }
    func testSummariesUseApplicableOptionsAndReadbackOnly() {
        XCTAssertFalse(CleaningOptions.standard.summary(for: .mop).contains("suction"))
        XCTAssertFalse(CleaningOptions.standard.summary(for: .vacuum).contains("moisture"))
        XCTAssertTrue(CleaningOptions(passes: 2).summary(for: .vacuumThenMop).contains("2 vacuum + 2 mop"))
        XCTAssertTrue(CleaningTaskSample(roomID: 1, parameters: [:]).reportedSettings.isEmpty)
        XCTAssertEqual(CleaningTaskSample(roomID: 1, parameters: [1: 999, 2: 99, 4: 99]).reportedSettings, ["Mode 999"])
        XCTAssertEqual(CleaningTaskSample(roomID: 1, parameters: [1: 5, 2: 3, 4: 1, 5: 1, 6: 2, 8: 2]).reportedSettings,
                       ["Vacuum, then mop", "Strong suction", "Low moisture", "1 vacuum pass", "2 mop passes", "Intensive route"])
    }
    func testDockContactIsDecodedIndependentlyOfWorkingState() throws {
        for raw in [UInt64(0), 1, 2, 3, 99] {
            let status = NarwalCodec.encodeBytes(3, NarwalCodec.encodeNumber(1, 1)) + NarwalCodec.encodeNumber(11, raw)
            let payload = NarwalCodec.encodeNumber(1, 1) + NarwalCodec.encodeBytes(2, status)
            let decoded = try NarwalCodec.status(Data([1, UInt8(payload.count)]) + payload)
            XCTAssertEqual(decoded.workingCode, 1)
            XCTAssertEqual(decoded.stationContactCode, Int(raw))
            XCTAssertEqual(decoded.stationContactLabel, [1: "Away from dock", 2: "Dock contact", 3: "Charging contact"][Int(raw)])
            XCTAssertEqual(decoded.label, "Standby")
        }
        XCTAssertNil(RobotStatus(battery: 100, workingCode: 1).stationContactLabel)
    }
}
