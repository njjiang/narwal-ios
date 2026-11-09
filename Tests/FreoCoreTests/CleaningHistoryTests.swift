import Foundation
import XCTest
@testable import FreoCore

final class CleaningHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FreoHistoryTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func observe(_ store: CleaningHistoryStore, _ snapshot: MapSnapshot, window: UUID) async throws -> [CleaningRun] {
        try await store.observe(snapshot: snapshot, trajectory: NarwalCodec.trajectory(snapshot: snapshot), windowID: window)
    }

    func testPushHistoryPreservesBaselineTimeAndRequiresBoundedSameMapScope() async throws {
        let store = CleaningHistoryStore(directory: try directory()), window = UUID()
        let baseline = RouteFixture.snapshot(at: Date().addingTimeInterval(-30), sequence: 10)
        let first = try await observe(store, baseline, window: window)
        let pushed = RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7)],
            at: baseline.capturedAt.addingTimeInterval(15), sequence: 11)
        let route = try NarwalCodec.trajectory(snapshot: pushed)
        let saved = try await store.observeLive(snapshot: baseline, trajectory: route, windowID: window)
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved[0].id, first[0].id)
        XCTAssertEqual(saved[0].updatedAt, pushed.capturedAt)
        XCTAssertEqual(saved[0].floorplan, baseline.floorplan)
        do {
            _ = try await store.observe(snapshot: baseline, trajectory: route, windowID: window)
            XCTFail("Ordinary reads must still have matching capture times")
        } catch { }
        for invalid in [
            RouteFixture.snapshot(at: baseline.capturedAt.addingTimeInterval(61), sequence: 12),
            RouteFixture.snapshot(at: baseline.capturedAt.addingTimeInterval(-1), sequence: 12),
            RouteFixture.snapshot(at: baseline.capturedAt.addingTimeInterval(15), sequence: 12, revision: 2),
            RouteFixture.snapshot(at: baseline.capturedAt.addingTimeInterval(15), sequence: 12, device: String(repeating: "b", count: 32))
        ] {
            do {
                _ = try await store.observeLive(snapshot: baseline, trajectory: NarwalCodec.trajectory(snapshot: invalid), windowID: window)
                XCTFail("A stale or cross-scope push must not be archived")
            } catch { }
        }
    }

    func testCumulativePrefixUpdatesOneRecordWithFrozenMapAndNoInventedCompletion() async throws {
        let folder = try directory(), store = CleaningHistoryStore(directory: folder), window = UUID(), date = Date()
        let first = RouteFixture.snapshot(at: date)
        let a = try await observe(store, first, window: window)
        let next = RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7)], at: date.addingTimeInterval(15), sequence: 2)
        let b = try await observe(store, next, window: window)
        XCTAssertEqual(a.count, 1); XCTAssertEqual(b.count, 1); XCTAssertEqual(a[0].id, b[0].id)
        XCTAssertEqual(b[0].trajectory.points.count, 4); XCTAssertEqual(b[0].observationCount, 2)
        XCTAssertEqual(b[0].floorplan, first.floorplan); XCTAssertEqual(b[0].startedAt, date)
        XCTAssertEqual(b[0].partialReason, CleaningHistoryStore.partialCaptureReason)
        XCTAssertNil(b[0].modeName); XCTAssertEqual(b[0].roomNames, [])
        let disk = try await CleaningHistoryStore(directory: folder).load()
        XCTAssertEqual(disk, b)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: files[0])
        XCTAssertFalse(text.contains("staticMapPayload")); XCTAssertFalse(text.contains("password")); XCTAssertFalse(text.contains("token"))
    }

    func testReportedTaskLabelsEnrichAndSurviveContinuousPartialRecording() async throws {
        let folder = try directory(), store = CleaningHistoryStore(directory: folder), window = UUID(), date = Date()
        let first = RouteFixture.snapshot(at: date)
        let initial = try await observe(store, first, window: window)
        let next = RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7)], at: date.addingTimeInterval(15), sequence: 2)
        let named = try await store.observe(snapshot: next, trajectory: NarwalCodec.trajectory(snapshot: next),
            windowID: window, modeName: "Vacuum", roomNames: ["entryway"])
        XCTAssertEqual(named.count, 1)
        XCTAssertEqual(named[0].id, initial[0].id)
        XCTAssertEqual(named[0].modeName, "Vacuum")
        XCTAssertEqual(named[0].roomNames, ["entryway"])
        let later = RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7), (4, 6)],
                                          at: date.addingTimeInterval(30), sequence: 3)
        let retained = try await store.observeLive(snapshot: next, trajectory: NarwalCodec.trajectory(snapshot: later), windowID: window)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained[0].modeName, "Vacuum")
        XCTAssertEqual(retained[0].roomNames, ["entryway"])
        let disk = try await CleaningHistoryStore(directory: folder).load()
        XCTAssertEqual(disk, retained)
        let changed = RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7), (4, 6), (5, 5)],
                                            at: date.addingTimeInterval(40), sequence: 4)
        let separate = try await store.observe(snapshot: changed, trajectory: NarwalCodec.trajectory(snapshot: changed),
            windowID: window, modeName: "Mop", roomNames: ["Kitchen"])
        XCTAssertEqual(separate.count, 2)
        XCTAssertTrue(separate.contains { $0.modeName == "Vacuum" && $0.roomNames == ["entryway"] })
        XCTAssertTrue(separate.contains { $0.modeName == "Mop" && $0.roomNames == ["Kitchen"] })
    }

    func testResetGapScopeRevisionAndChangedRasterStartSeparateRecords() async throws {
        let date = Date()
        let cases: [MapSnapshot] = [
            RouteFixture.snapshot(points: [(4, 6), (5, 5)], at: date.addingTimeInterval(15), sequence: 2),
            RouteFixture.snapshot(points: [(0, 10), (1, 9)], at: date.addingTimeInterval(15), sequence: 2),
            RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7)], at: date.addingTimeInterval(60), sequence: 2),
            RouteFixture.snapshot(at: date.addingTimeInterval(15), sequence: 2, revision: 2),
            RouteFixture.snapshot(at: date.addingTimeInterval(15), sequence: 2, device: String(repeating: "b", count: 32)),
            RouteFixture.snapshot(at: date.addingTimeInterval(15), sequence: 2, pixels: [0x120] + Array(repeating: 0x101, count: 99)),
            RouteFixture.snapshot(at: date.addingTimeInterval(15), sequence: 2, replaceInfo: RouteFixture.info(0, 1))
        ]
        for next in cases {
            let store = CleaningHistoryStore(directory: try directory()), window = UUID()
            let a = try await observe(store, RouteFixture.snapshot(at: date), window: window)
            let b = try await observe(store, next, window: window)
            XCTAssertEqual(b.count, 2); XCTAssertNotEqual(b[0].id, a[0].id)
        }
    }

    func testNewWindowDoesNotResumeOldRecordOrDuplicateStationaryPath() async throws {
        let store = CleaningHistoryStore(directory: try directory()), date = Date(), window = UUID()
        let a = try await observe(store, RouteFixture.snapshot(at: date), window: window)
        let unchanged = try await observe(store, RouteFixture.snapshot(at: date.addingTimeInterval(10), sequence: 2), window: UUID())
        XCTAssertEqual(a, unchanged)
        let next = try await observe(store, RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7)], at: date.addingTimeInterval(20), sequence: 3), window: UUID())
        XCTAssertEqual(next.count, 2); XCTAssertNotEqual(next[0].id, a[0].id)
    }

    func testKnownRuntimePixelsAndRepeatedHistoryLoadDoNotSplitObservationWindow() async throws {
        let store = CleaningHistoryStore(directory: try directory()), date = Date(), window = UUID()
        let a = try await observe(store, RouteFixture.snapshot(at: date), window: window)
        _ = try await store.load()
        let pixels = Array(repeating: UInt32(0x101) ^ UInt32(0x1001_0043), count: 100)
        let b = try await observe(store, RouteFixture.snapshot(points: [(0, 10), (1, 9), (2, 8), (3, 7)],
            at: date.addingTimeInterval(15), sequence: 2, pixels: pixels), window: window)
        XCTAssertEqual(b.count, 1); XCTAssertEqual(b[0].id, a[0].id)
        XCTAssertEqual(b[0].floorplan.pixels, a[0].floorplan.pixels)
        // Room labels, wall, unreachable, and unknown non-runtime bits split.
        for bit: UInt32 in [0x100, 0x20, 0x10, 0x80] {
            let isolated = CleaningHistoryStore(directory: try directory())
            _ = try await observe(isolated, RouteFixture.snapshot(at: date), window: window)
            let changed = [UInt32(0x101) ^ bit] + Array(repeating: UInt32(0x101), count: 99)
            let result = try await observe(isolated, RouteFixture.snapshot(at: date.addingTimeInterval(15), sequence: 2, pixels: changed), window: window)
            XCTAssertEqual(result.count, 2)
        }
    }

    func testRegressingSequenceOrTimestampCannotExtendExistingRecord() async throws {
        let date = Date(), points: [(Float, Float)] = [(0, 10), (1, 9), (2, 8), (3, 7)]
        for next in [
            RouteFixture.snapshot(points: points, at: date.addingTimeInterval(10), sequence: 1),
            RouteFixture.snapshot(points: points, at: date.addingTimeInterval(10), sequence: 3, timestamp: UInt64(date.addingTimeInterval(-10).timeIntervalSince1970 * 1000))
        ] {
            let store = CleaningHistoryStore(directory: try directory()), window = UUID()
            _ = try await observe(store, RouteFixture.snapshot(at: date, sequence: 2), window: window)
            let records = try await observe(store, next, window: window)
            XCTAssertEqual(records.count, 2)
        }
    }

    func testMissingStaleOrPoseOnlyTelemetryDoesNotCreateJunkHistory() async throws {
        let store = CleaningHistoryStore(directory: try directory()), date = Date()
        for snapshot in [
            RouteFixture.snapshot(points: [(0, 10)], at: date),
            RouteFixture.snapshot(points: [(0, 10), (0, 10)], at: date),
            RouteFixture.snapshot(at: date, timestamp: UInt64(date.addingTimeInterval(-1000).timeIntervalSince1970 * 1000)),
            RouteFixture.snapshot(at: date, timestamp: UInt64.max),
            RouteFixture.snapshot(at: date, format: 3)
        ] { let result = try await observe(store, snapshot, window: UUID()); XCTAssertTrue(result.isEmpty) }
    }

    func testDemoAndMismatchedIdentityCannotEnterLiveArchive() async throws {
        let store = CleaningHistoryStore(directory: try directory()), snapshot = RouteFixture.snapshot()
        let original = try NarwalCodec.trajectory(snapshot: snapshot)
        let demo = RobotTrajectory(productKey: original.productKey, deviceID: original.deviceID, mapID: original.mapID,
            mapVersion: original.mapVersion, editVersion: original.editVersion, points: original.points,
            segments: original.segments, pose: nil, capturedAt: original.capturedAt,
            deviceTimestampMilliseconds: original.deviceTimestampMilliseconds, sequenceID: original.sequenceID, isSimulated: true)
        let result = try await store.observe(snapshot: snapshot, trajectory: demo, windowID: UUID())
        XCTAssertTrue(result.isEmpty)
        do {
            _ = try await store.observe(snapshot: RouteFixture.snapshot(device: String(repeating: "b", count: 32)), trajectory: original, windowID: UUID())
            XCTFail("Cross-device telemetry must fail")
        } catch { }
    }

    func testRetentionIndividualDeleteAndMalformedFilesStayBounded() async throws {
        let folder = try directory(), store = CleaningHistoryStore(directory: folder, maximumRecords: 2), date = Date()
        var result: [CleaningRun] = []
        for i in 0..<4 {
            let x = Float(i)
            result = try await observe(store, RouteFixture.snapshot(points: [(x, 10), (x + 1, 9)], at: date.addingTimeInterval(Double(i)), sequence: UInt64(i)), window: UUID())
        }
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        let remaining = try await store.delete(id: result[0].id)
        XCTAssertEqual(remaining.count, 1)
        try Data("{invalid".utf8).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"))
        let reread = try await CleaningHistoryStore(directory: folder).load()
        XCTAssertEqual(reread.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        try await store.clear()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testUntrustedStoredCoordinatesAndSymlinkRecordsAreRejected() async throws {
        let folder = try directory(), store = CleaningHistoryStore(directory: folder)
        _ = try await observe(store, RouteFixture.snapshot(), window: UUID())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var run = json["run"] as! [String: Any], trajectory = run["trajectory"] as! [String: Any]
        trajectory["points"] = [["x": 9999999, "y": 0]]; run["trajectory"] = trajectory; json["run"] = run
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let outside = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("private unrelated file".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(UUID().uuidString + ".json"), withDestinationURL: outside)
        let result = try await CleaningHistoryStore(directory: folder).load()
        XCTAssertTrue(result.isEmpty); XCTAssertEqual(try String(contentsOf: outside), "private unrelated file")
    }

    func testFutureCaptureAndForgedStoredFreshnessDatesAreRejected() async throws {
        let futureStore = CleaningHistoryStore(directory: try directory())
        do {
            _ = try await observe(futureStore, RouteFixture.snapshot(at: Date().addingTimeInterval(3600)), window: UUID())
            XCTFail("A future capture must not become a history record")
        } catch { }
        for change in ["timestamp", "long-window", "future"] {
            let folder = try directory(), store = CleaningHistoryStore(directory: folder)
            _ = try await observe(store, RouteFixture.snapshot(), window: UUID())
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var run = json["run"] as! [String: Any], trajectory = run["trajectory"] as! [String: Any]
            if change == "timestamp" { trajectory["deviceTimestampMilliseconds"] = UInt64.max }
            if change == "long-window" { run["startedAt"] = Date().addingTimeInterval(-400 * 86_400).timeIntervalSinceReferenceDate }
            if change == "future" {
                let future = Date().addingTimeInterval(3600)
                run["startedAt"] = future.timeIntervalSinceReferenceDate; run["updatedAt"] = future.timeIntervalSinceReferenceDate
                trajectory["capturedAt"] = future.timeIntervalSinceReferenceDate
                trajectory["deviceTimestampMilliseconds"] = UInt64(future.timeIntervalSince1970 * 1000)
            }
            run["trajectory"] = trajectory; json["run"] = run
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            let result = try await CleaningHistoryStore(directory: folder).load()
            XCTAssertTrue(result.isEmpty)
        }
    }
}
