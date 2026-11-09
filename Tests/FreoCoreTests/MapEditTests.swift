import Foundation
import XCTest
@testable import FreoCore

final class MapEditTests: XCTestCase {
    private let robot = RobotDevice(id: String(repeating: "a", count: 32), productKey: "EHf6cRNRGT", name: "Test")
    private let uuid = String(repeating: "b", count: 32)
    private func integer(_ value: UInt64) -> Data {
        var value = value, output = Data()
        repeat { let part = UInt8(value & 127); value >>= 7; output.append(part | (value == 0 ? 0 : 128)) } while value != 0
        return output
    }
    private func number(_ tag: Int, _ value: UInt64) -> Data { integer(UInt64(tag << 3)) + integer(value) }
    private func bytes(_ tag: Int, _ value: Data) -> Data { integer(UInt64(tag << 3 | 2)) + integer(UInt64(value.count)) + value }
    private func frame(_ value: Data) -> Data { Data([1]) + integer(UInt64(value.count)) + value }
    private func map(_ edit: UInt64 = 9, room: Data? = nil) -> Data {
        let grid = Data([0x78, 0x9c, 0xe3, 0x62, 0x54, 0, 0, 0, 0x43, 0, 0x2c])
        var data = number(1, 17) + number(2, 3) + number(33, edit) + number(3, 60)
        data += number(4, 1) + number(5, 1) + bytes(17, grid)
        if let room { data += bytes(12, room) }
        return data
    }
    private func snapshot(_ edit: UInt64 = 9, room: Data? = nil) throws -> MapSnapshot {
        try NarwalCodec.mapSnapshot(frame(number(1, 1) + bytes(2, map(edit, room: room))), device: robot)
    }
    private func editable(_ edit: UInt64 = 9, outer: UInt64? = 9, extra: Data = Data()) -> Data {
        var body = number(1, 1) + bytes(2, map(edit))
        if let outer { body += number(3, outer) }
        return frame(body + extra)
    }

    func testEditableReadUsesExplicitMapAndStrictVersionAgreement() throws {
        XCTAssertEqual(try NarwalCodec.editableMapRequest(uuid: uuid, mapID: 17), try NarwalCodec.identity(uuid: uuid) + Data([8, 17, 16, 0, 24, 0, 32, 0]))
        let value = try NarwalCodec.editableMapSnapshot(editable(extra: bytes(4, number(1, 32))), device: robot, mapID: 17)
        XCTAssertEqual(value.editVersion, 9); XCTAssertEqual(value.maximumRoomCount, 32)
        for invalid in [editable(outer: nil), editable(outer: 10), editable(extra: number(3, 9)), editable(extra: number(5, 2)), editable(extra: bytes(4, number(1, 256)))] {
            XCTAssertThrowsError(try NarwalCodec.editableMapSnapshot(invalid, device: robot, mapID: 17))
        }
        XCTAssertThrowsError(try NarwalCodec.editableMapSnapshot(editable(), device: robot, mapID: 18))
        XCTAssertThrowsError(try NarwalCodec.editableMapRequest(uuid: uuid, mapID: 0))
    }

    func testSplitAndMergeMatchRecoveredSchemaAndFloat32WireFormat() throws {
        let original = try snapshot()
        let operations: [RoomMapOperation] = [.split(start: MapEditPoint(x: 1.25, y: -2.5), end: MapEditPoint(x: 4, y: 3), leftRoomID: 7, rightRoomID: 8), .merge(roomID1: 8, roomID2: 2, newRoomID: 9)]
        // Point fields are little-endian fixed32, not doubles or scaled integers.
        let start = Data([0x0d, 0, 0, 0xa0, 0x3f, 0x15, 0, 0, 0x20, 0xc0])
        let end = Data([0x0d, 0, 0, 0x80, 0x40, 0x15, 0, 0, 0x40, 0x40])
        let split = bytes(1, bytes(1, start) + bytes(2, end) + Data([24, 7, 32, 8]))
        let merge = bytes(2, Data([8, 8, 16, 2, 24, 9]))
        let expected = try NarwalCodec.identity(uuid: uuid) + Data([8, 17, 16, 3, 24, 9]) + bytes(4, split) + bytes(4, merge) + Data([40, 0, 48, 0, 56, 0])
        XCTAssertEqual(try NarwalCodec.roomOperationRequest(uuid: uuid, baseline: original, operations: operations), expected)
    }

    func testRenamePreservesEveryOtherRoomMetadataByte() throws {
        let untouched = number(1, 7) + number(2, 4) + bytes(21, Data([0, 255, 1])) + number(22, UInt64.max) + number(22, 8)
        let originalRoom = bytes(3, Data("Old name".utf8)) + untouched
        let baseline = try snapshot(room: originalRoom)
        let renamed = untouched + bytes(3, Data("Kitchen".utf8))
        let expected = try NarwalCodec.identity(uuid: uuid) + Data([8, 17, 16, 3, 24, 9]) + bytes(4, bytes(3, bytes(1, renamed))) + Data([40, 0, 48, 0, 56, 0])
        XCTAssertEqual(try NarwalCodec.roomOperationRequest(uuid: uuid, baseline: baseline, operations: [.rename(roomID: 7, name: "Kitchen")]), expected)
        XCTAssertThrowsError(try NarwalCodec.roomOperationRequest(uuid: uuid, baseline: baseline, operations: [.rename(roomID: 8, name: "Hallway")]))
        for name in ["", " \n", "A\u{0}B", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try NarwalCodec.roomOperationRequest(uuid: uuid, baseline: baseline, operations: [.rename(roomID: 7, name: name)]))
        }
    }

    func testUnsafeOrEmptyOperationsAreRejectedOffline() throws {
        let baseline = try snapshot(), zero = MapEditPoint(x: 0, y: 0), one = MapEditPoint(x: 1, y: 1)
        let invalid: [[RoomMapOperation]] = [[], [.split(start: zero, end: zero, leftRoomID: 1, rightRoomID: 2)], [.split(start: zero, end: one, leftRoomID: 1, rightRoomID: 1)], [.split(start: MapEditPoint(x: .nan, y: 0), end: one, leftRoomID: 1, rightRoomID: 2)], [.merge(roomID1: 1, roomID2: 1, newRoomID: 2)], [.merge(roomID1: 1, roomID2: 2, newRoomID: 256)], Array(repeating: .merge(roomID1: 1, roomID2: 2, newRoomID: 3), count: 65)]
        for operations in invalid { XCTAssertThrowsError(try NarwalCodec.roomOperationRequest(uuid: uuid, baseline: baseline, operations: operations)) }
    }

    func testAcknowledgementsDoNotTreatFailureOrStaleVersionAsSuccess() throws {
        XCTAssertTrue(try NarwalCodec.mapEditAcknowledgement(frame(number(1, 1) + number(3, 10))).accepted)
        let stale = try NarwalCodec.mapEditAcknowledgement(frame(number(1, 2) + number(3, 10) + number(4, 1)))
        XCTAssertFalse(stale.accepted); XCTAssertEqual(stale.errorCode, 1)
        XCTAssertFalse(try NarwalCodec.mapEditAcknowledgement(frame(number(1, 3))).accepted)
        for malformed in [number(1, 1), number(1, 1) + number(3, 10) + number(3, 11), number(1, 1) + bytes(3, Data()), number(1, 1) + number(3, UInt64(UInt32.max) + 1)] {
            XCTAssertThrowsError(try NarwalCodec.mapEditAcknowledgement(frame(malformed)))
        }
    }

    func testSnapshotPreconditionRequiresExactScopeRevisionsAndBytes() throws {
        let baseline = try snapshot()
        XCTAssertNoThrow(try MapEditTransaction.validate(current: baseline, baseline: baseline))
        XCTAssertThrowsError(try MapEditTransaction.validate(current: snapshot(10), baseline: baseline))
        XCTAssertThrowsError(try MapEditTransaction.validate(current: snapshot(room: number(1, 1)), baseline: baseline))
        let otherRobot = RobotDevice(id: String(repeating: "c", count: 32), productKey: robot.productKey, name: "Other")
        let other = try NarwalCodec.mapSnapshot(frame(number(1, 1) + bytes(2, map())), device: otherRobot)
        XCTAssertThrowsError(try MapEditTransaction.validate(current: other, baseline: baseline))
    }

    func testReadbackPreservesOpaqueMapFieldsAndRejectsUnknownChanges() throws {
        let baseline = try snapshot()
        XCTAssertNoThrow(try NarwalCodec.validateRoomEditReadback(baseline: baseline, current: snapshot(10, room: number(1, 7))))
        for changed in [map(10) + bytes(109, Data([1, 2])), map(10) + number(110, 1)] {
            let current = try NarwalCodec.mapSnapshot(frame(number(1, 1) + bytes(2, changed)), device: robot)
            XCTAssertThrowsError(try NarwalCodec.validateRoomEditReadback(baseline: baseline, current: current))
        }
        let first = try NarwalCodec.mapSnapshot(frame(number(1, 1) + bytes(2, bytes(109, Data([1, 2])) + map())), device: robot)
        let reordered = try NarwalCodec.mapSnapshot(frame(number(1, 1) + bytes(2, map(10) + bytes(109, Data([1, 2])))), device: robot)
        XCTAssertNoThrow(try NarwalCodec.validateRoomEditReadback(baseline: first, current: reordered))
        XCTAssertThrowsError(try NarwalCodec.validateRoomEditReadback(baseline: first, current: baseline))
    }

    func testReadbackPreservesUnselectedRoomNamesAndOpaqueMetadata() throws {
        let selected = number(1, 7) + bytes(3, Data("Kitchen".utf8))
        let other = number(1, 8) + bytes(3, Data("Bedroom".utf8)) + bytes(29, Data([0, 255, 3]))
        func saved(_ revision: UInt64, _ records: [Data]) throws -> MapSnapshot {
            let payload = records.reduce(map(revision)) { $0 + bytes(12, $1) }
            return try NarwalCodec.mapSnapshot(frame(number(1, 1) + bytes(2, payload)), device: robot)
        }
        let baseline = try saved(9, [selected, other])
        let renamed = number(1, 7) + bytes(3, Data("Hallway".utf8))
        let allowed = try saved(10, [other, renamed, number(1, 9)])
        XCTAssertNoThrow(try NarwalCodec.validateRoomEditReadback(baseline: baseline, current: allowed, mutableRoomIDs: [7]))
        XCTAssertThrowsError(try NarwalCodec.validateRoomEditReadback(baseline: baseline, current: allowed))
        let changedName = number(1, 8) + bytes(3, Data("Wrong name".utf8)) + bytes(29, Data([0, 255, 3]))
        let changedUnknown = number(1, 8) + bytes(3, Data("Bedroom".utf8)) + bytes(29, Data([0, 255, 4]))
        for records in [[renamed, changedName], [renamed, changedUnknown], [renamed]] {
            XCTAssertThrowsError(try NarwalCodec.validateRoomEditReadback(baseline: baseline, current: saved(10, records), mutableRoomIDs: [7]))
        }
        XCTAssertThrowsError(try NarwalCodec.validateRoomEditReadback(baseline: baseline, current: allowed, mutableRoomIDs: [99]))
    }

    func testCommitAcknowledgementRequiresFreshReadbackAndNeverResends() async throws {
        let baseline = try snapshot(), changed = try snapshot(10), url = URL(fileURLWithPath: "/offline/snapshot.json")
        var sends = 0, reads = 0
        let result = try await MapEditTransaction.commit(baseline: baseline, preservedSnapshotURL: url, send: {
            sends += 1; return self.frame(self.number(1, 1) + self.number(3, 10))
        }, readBack: { reads += 1; return changed }, preserveReadback: { _ in })
        XCTAssertTrue(result.acknowledged); XCTAssertEqual(result.snapshot.editVersion, 10)
        XCTAssertEqual(sends, 1); XCTAssertEqual(reads, 1)
        sends = 0; reads = 0
        let unknown = try await MapEditTransaction.commit(baseline: baseline, preservedSnapshotURL: url, send: {
            sends += 1; throw ConnectorError.outcomeUnknown
        }, readBack: { reads += 1; return changed }, preserveReadback: { _ in })
        XCTAssertFalse(unknown.acknowledged); XCTAssertEqual(sends, 1); XCTAssertEqual(reads, 1)
    }

    func testRejectedAndUnchangedReadbacksFailWithoutRetry() async throws {
        let baseline = try snapshot(), url = URL(fileURLWithPath: "/offline/snapshot.json")
        var reads = 0
        do {
            _ = try await MapEditTransaction.commit(baseline: baseline, preservedSnapshotURL: url, send: { self.frame(self.number(1, 2) + self.number(4, 1)) }, readBack: { reads += 1; return baseline }, preserveReadback: { _ in })
            XCTFail("A stale edit must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("version changed")) }
        XCTAssertEqual(reads, 0)
        var sends = 0
        do {
            _ = try await MapEditTransaction.commit(baseline: baseline, preservedSnapshotURL: url, send: { sends += 1; throw ConnectorError.outcomeUnknown }, readBack: { reads += 1; return baseline }, preserveReadback: { _ in })
            XCTFail("No advanced revision is not evidence of save")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No automatic retry")) }
        XCTAssertEqual(sends, 1); XCTAssertEqual(reads, 1)
    }

    func testOldRevisionAndUnreadableAcknowledgementsStayUnconfirmed() async throws {
        let baseline = try snapshot(), changed = try snapshot(10), url = URL(fileURLWithPath: "/offline/snapshot.json")
        for reply in [frame(number(1, 1) + number(3, 9)), Data([1, 255])] {
            var sends = 0, reads = 0
            let result = try await MapEditTransaction.commit(baseline: baseline, preservedSnapshotURL: url, send: { sends += 1; return reply }, readBack: { reads += 1; return changed }, preserveReadback: { _ in })
            XCTAssertFalse(result.acknowledged); XCTAssertEqual(sends, 1); XCTAssertEqual(reads, 1)
        }
        do {
            _ = try await MapEditTransaction.commit(baseline: baseline, preservedSnapshotURL: url, send: { self.frame(self.number(1, 1) + self.number(3, 11)) }, readBack: { changed }, preserveReadback: { _ in })
            XCTFail("Readback older than acknowledged edit must not pass")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not be verified")) }
    }

    func testSnapshotDiskRecordIsPrivateExactAndContainsNoSessionEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try snapshot(), url = try MapSnapshotStore.preserve(baseline, directory: directory)
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let raw = try XCTUnwrap(object["staticMapPayload"] as? String)
        XCTAssertEqual(Data(base64Encoded: raw), baseline.staticMapPayload)
        XCTAssertNil(object["token"]); XCTAssertNil(object["uuid"]); XCTAssertNil(object["password"])
        XCTAssertTrue((object["purpose"] as? String)?.contains("restoration is not implemented") == true)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertFalse(url.lastPathComponent.contains(robot.id))
    }

    func testRejectedPostWriteReadbackIsPreservedBeforeRevisionValidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try snapshot(), unchanged = try snapshot()
        var sends = 0
        do {
            _ = try await MapEditTransaction.commit(baseline: baseline,
                preservedSnapshotURL: URL(fileURLWithPath: "/offline/baseline.json"),
                send: { sends += 1; return self.frame(self.number(1, 1) + self.number(3, 10)) },
                readBack: { unchanged },
                preserveReadback: { _ = try MapSnapshotStore.preserveReadback($0, directory: directory) })
            XCTFail("An unchanged revision must still be rejected")
        } catch { XCTAssertTrue(error is MapEditError) }
        XCTAssertEqual(sends, 1)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["staticMapPayload"] as? String)), unchanged.staticMapPayload)
        XCTAssertTrue((object["purpose"] as? String)?.contains("before validation") == true)
        XCTAssertNil(object["token"]); XCTAssertNil(object["password"]); XCTAssertNil(object["uuid"])
    }

    func testReadbackStorageFailureStopsWithoutResending() async throws {
        let baseline = try snapshot(), changed = try snapshot(10)
        var sends = 0, saves = 0
        do {
            _ = try await MapEditTransaction.commit(baseline: baseline,
                preservedSnapshotURL: URL(fileURLWithPath: "/offline/baseline.json"),
                send: { sends += 1; return self.frame(self.number(1, 1) + self.number(3, 10)) },
                readBack: { changed }, preserveReadback: { _ in
                    saves += 1; throw CocoaError(.fileWriteOutOfSpace)
                })
            XCTFail("A readback without diagnostic preservation must stop the transaction")
        } catch { XCTAssertTrue(error is MapEditError) }
        XCTAssertEqual(sends, 1); XCTAssertEqual(saves, 1)
    }

    func testReadbackRetentionIsBoundedAndDoesNotPruneOriginalBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try snapshot()
        let backup = try MapSnapshotStore.preserve(baseline, directory: directory)
        let readbacks = directory.appendingPathComponent("Readbacks", isDirectory: true)
        var latest: URL?
        for _ in 0..<(MapSnapshotStore.maximumReadbackRecords + 3) {
            latest = try MapSnapshotStore.preserveReadback(baseline, directory: readbacks)
        }
        let files = try FileManager.default.contentsOfDirectory(at: readbacks, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, MapSnapshotStore.maximumReadbackRecords)
        XCTAssertTrue(files.map(\.lastPathComponent).contains(try XCTUnwrap(latest).lastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(latest).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: readbacks.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testMapEditServiceCannotReadOrWriteWithoutSigningIn() async throws {
        let service = NarwalService(), baseline = try snapshot()
        do { _ = try await service.editableMapSnapshot(device: robot, mapID: 17); XCTFail("No session") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Sign in")) }
        do { _ = try await service.applyRoomOperations(device: robot, baseline: baseline, operations: [.merge(roomID1: 1, roomID2: 2, newRoomID: 3)]); XCTFail("No session") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Sign in")) }
    }
}
