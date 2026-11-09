import Foundation
import XCTest
import zlib
@testable import FreoCore

private enum EditWireFixture {
    static let uuid = String(repeating: "b", count: 32)
    static let device = RobotDevice(id: String(repeating: "a", count: 32), productKey: "EHf6cRNRGT", name: "Offline fixture")
    static func integer(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { let low = UInt8(value & 127); value >>= 7; data.append(low | (value == 0 ? 0 : 128)) } while value != 0
        return data
    }
    static func number(_ tag: Int, _ value: UInt64) -> Data { integer(UInt64(tag << 3)) + integer(value) }
    static func bytes(_ tag: Int, _ value: Data) -> Data { integer(UInt64(tag << 3 | 2)) + integer(UInt64(value.count)) + value }
    static func deflate(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count)), output = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))))
        let code = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &length,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard code == Z_OK else { throw ConnectorError.invalid("Offline compression fixture failed.") }
        return Data(output.prefix(Int(length)))
    }
    static func map(pixels: [UInt32], names: [Int: String], revision: UInt32, corruptGrid: Bool = false) throws -> Data {
        let border = number(1, UInt64(bitPattern: -6)) + number(2, 0) + number(3, 20) + number(4, 28)
        var value = number(1, 17) + number(2, 3) + number(3, 60) + number(4, 8) + number(5, 6) + bytes(6, border)
        for id in names.keys.sorted() {
            let record = number(1, UInt64(id)) + number(2, 0) + bytes(3, Data(names[id]!.utf8)) + bytes(50, Data([0, 255, 7]))
            value += bytes(12, record)
        }
        let packed = pixels.reduce(Data()) { $0 + integer(UInt64($1)) }
        let grid = try corruptGrid ? Data([0x78, 0x9c, 0xff]) : deflate(bytes(1, packed))
        return value + bytes(17, grid) + number(25, 0) + number(33, UInt64(revision)) + bytes(100, Data([1, 0, 255]))
    }
    static func response(map: Data, revision: UInt32, outerRevision: UInt32? = nil) throws -> Data {
        // Actual response framing: declared identity prefix followed by body.
        try NarwalCodec.identity(uuid: uuid) + number(1, 1) + bytes(2, map)
            + number(3, UInt64(outerRevision ?? revision)) + bytes(4, number(1, 32)) + number(5, 0)
    }
    static func acknowledgement(map: Data, revision: UInt32, rejected: Bool = false) throws -> Data {
        try NarwalCodec.identity(uuid: uuid) + number(1, rejected ? 2 : 1) + bytes(2, map)
            + number(3, UInt64(revision)) + number(4, rejected ? 1 : 0) + number(5, 0)
    }
    /// Executes the production topic helper, MQTT handshake and publication
    /// parser entirely in memory. No socket/network implementation is called.
    static func mqtt(suffix: String, payload: Data, reply: Data, command: Bool) throws -> Data {
        let topic = NarwalService.mqttTopic(device: device, suffix: suffix), correlation = Data([1, 2, 3])
        var session = try MQTTSession(uuid: uuid, token: "offline-test-token", device: device,
                                     topic: topic, payload: payload, correlation: correlation, isCommand: command)
        _ = try session.receive(MQTTFrame(header: 0x20, body: Data([0, 0, 0])))
        let outgoing = try session.receive(MQTTFrame(header: 0x90, body: Data([0, 1, 0, 0])))
        guard outgoing.count == 1 else { throw ConnectorError.invalid("Offline fixture expected one publication.") }
        var decoder = MQTTFrameDecoder()
        let publication = try MQTTCodec.decodePublish(decoder.append(outgoing[0])[0])
        guard publication.topic == topic, publication.payload == payload else { throw ConnectorError.invalid("Offline request changed in MQTT framing.") }
        let incoming = try MQTTCodec.publish(topic: topic + "/response", responseTopic: topic + "/response", payload: reply, correlation: correlation)
        for frame in try decoder.append(incoming) { _ = try session.receive(frame) }
        guard let response = session.response else { throw ConnectorError.invalid("Offline fixture reply was not accepted.") }
        return response
    }
    struct State { let map: Data; let response: Data; let revision: UInt32 }
    static func scenario(corruptGridAt: Int? = nil, wrongRevisionAt: Int? = nil, otherRoomRenameAt: Int? = nil) throws -> (RoomPartitionPlan, [State]) {
        let original: [UInt32] = (0..<48).map { index in
            let x = index % 8, y = 5 - index / 8, id = x >= 6 ? 9 : (x > y ? 1 : 2)
            return 0x10000001 | UInt32(id << 8)
        }
        let initialMap = try map(pixels: original, names: [1: "Kitchen old", 2: "Hall old", 9: "Bedroom"], revision: 1)
        let initialReply = try response(map: initialMap, revision: 1)
        let baseline = try NarwalCodec.editableMapSnapshot(initialReply, device: device, mapID: 17)
        let plan = try RoomPartitionPlanner.make(floorplan: baseline.floorplan, sourceRoomIDs: [1, 2],
                                                rectangle: .init(minX: 3, minY: 2, maxXExclusive: 6, maxYExclusive: 6))
        let stages: [([Set<Int>], [Int])] = [([plan.sourceCells], [4]),
            ([plan.horizontalRemainderCells, plan.cornerBandCells], [4, 10]),
            ([plan.horizontalRemainderCells, plan.sideRemainderCells, plan.kitchenCells], [4, 10, 11]),
            ([plan.kitchenCells, plan.hallwayCells], [11, 4]), ([plan.kitchenCells, plan.hallwayCells], [11, 4])]
        var states = [State(map: initialMap, response: initialReply, revision: 1)]
        for (index, stage) in stages.enumerated() {
            let position = index + 1, revision = UInt32(position + 1)
            var pixels = original, names = [9: otherRoomRenameAt == position ? "Changed unexpectedly" : "Bedroom"]
            for (cells, id) in zip(stage.0, stage.1) {
                for cell in cells { pixels[cell] = (pixels[cell] & ~0xff00) | UInt32(id << 8) }
                names[id] = position == 5 ? (id == 11 ? "Kitchen" : "Hallway") : "Saved \(id)"
            }
            let raw = try map(pixels: pixels, names: names, revision: revision, corruptGrid: corruptGridAt == position)
            let reply = try response(map: raw, revision: revision, outerRevision: wrongRevisionAt == position ? revision + 1 : nil)
            states.append(State(map: raw, response: reply, revision: revision))
        }
        return (plan, states)
    }
}

private actor EncodedEditScenario {
    let states: [EditWireFixture.State]
    let rejectAt: Int?
    var position = 0
    var writes = 0
    var reads = 0
    init(states: [EditWireFixture.State], rejectAt: Int? = nil) { self.states = states; self.rejectAt = rejectAt }
    func read() throws -> MapSnapshot {
        reads += 1
        let request = try NarwalCodec.editableMapRequest(uuid: EditWireFixture.uuid, mapID: 17)
        let response = try EditWireFixture.mqtt(suffix: "map/get_editable_map", payload: request, reply: states[position].response, command: false)
        return try NarwalCodec.editableMapSnapshot(response, device: EditWireFixture.device, mapID: 17)
    }
    func send(_ payload: Data) throws -> Data {
        writes += 1; position += 1
        let state = states[position]
        let reply = try EditWireFixture.acknowledgement(map: state.map, revision: state.revision, rejected: writes == rejectAt)
        return try EditWireFixture.mqtt(suffix: "map/operation", payload: payload, reply: reply, command: true)
    }
    func apply(_ baseline: MapSnapshot, _ operations: [RoomMapOperation]) async throws -> MapEditCommitResult {
        let fresh = try read()
        try MapEditTransaction.validate(current: fresh, baseline: baseline)
        let payload = try NarwalCodec.roomOperationRequest(uuid: EditWireFixture.uuid, baseline: fresh, operations: operations)
        return try await MapEditTransaction.commit(baseline: fresh, preservedSnapshotURL: URL(fileURLWithPath: "/offline/unused.json"),
            send: { try self.send(payload) }, readBack: { try self.read() }, preserveReadback: { _ in })
    }
    func counts() -> (Int, Int) { (writes, reads) }
}

final class MapEditEndToEndTests: XCTestCase {
    private func commit(_ plan: RoomPartitionPlan, scenario: EncodedEditScenario) async throws -> MapSnapshot {
        let baseline = try await scenario.read()
        return try await RoomPartitionTransaction.commit(plan: plan, baseline: baseline, kitchenName: "Kitchen", hallwayName: "Hallway",
            read: { try await scenario.read() }, apply: { try await scenario.apply($0, $1) }, preserveReadback: { _ in }, progress: { _ in })
    }
    func testEncodedMQTTAcknowledgementsAndCompressedReadbacksReachVerifiedPartition() async throws {
        let (plan, states) = try EditWireFixture.scenario(), scenario = EncodedEditScenario(states: states)
        let result = try await commit(plan, scenario: scenario)
        XCTAssertEqual(try plan.validateFinalPartition(result.floorplan), [11, 4])
        XCTAssertEqual(result.floorplan.rooms.first(where: { $0.id == 11 })?.name, "Kitchen")
        XCTAssertEqual(result.floorplan.rooms.first(where: { $0.id == 4 })?.name, "Hallway")
        XCTAssertEqual(result.floorplan.rooms.first(where: { $0.id == 9 })?.name, "Bedroom")
        XCTAssertEqual(result.floorplan.mapRevision, 6)
        let counts = await scenario.counts()
        XCTAssertEqual(counts.0, 5)
        XCTAssertEqual(counts.1, 17) // initial + transaction checks + per-send fresh/readback
    }
    func testCorruptCompressedGridOrMismatchedRevisionStopsAfterSecondWrite() async throws {
        for mismatch in [false, true] {
            let (plan, states) = try EditWireFixture.scenario(corruptGridAt: mismatch ? nil : 2, wrongRevisionAt: mismatch ? 2 : nil)
            let scenario = EncodedEditScenario(states: states)
            do { _ = try await commit(plan, scenario: scenario); XCTFail("Corrupt wire readback must stop the sequence") }
            catch let error as RoomPartitionTransactionError { XCTAssertEqual(error.completedSteps, 1); XCTAssertTrue(error.mayHaveChanged) }
            let counts = await scenario.counts()
            XCTAssertEqual(counts.0, 2)
        }
    }
    func testValidlyEncodedChangeToUnselectedRoomStopsFurtherWrites() async throws {
        let (plan, states) = try EditWireFixture.scenario(otherRoomRenameAt: 1), scenario = EncodedEditScenario(states: states)
        do { _ = try await commit(plan, scenario: scenario); XCTFail("Unselected room change must stop the sequence") }
        catch let error as RoomPartitionTransactionError { XCTAssertEqual(error.completedSteps, 0); XCTAssertTrue(error.detail.contains("unselected room")) }
        let counts = await scenario.counts()
        XCTAssertEqual(counts.0, 1)
    }
    func testEncodedStaleVersionRejectionDoesNotRetryOrSendNextStep() async throws {
        let (plan, states) = try EditWireFixture.scenario(), scenario = EncodedEditScenario(states: states, rejectAt: 2)
        do { _ = try await commit(plan, scenario: scenario); XCTFail("Rejected edit must stop the sequence") }
        catch let error as RoomPartitionTransactionError { XCTAssertEqual(error.completedSteps, 1); XCTAssertTrue(error.detail.contains("version changed")) }
        let counts = await scenario.counts()
        XCTAssertEqual(counts.0, 2)
    }
}
