import Foundation
import XCTest
@testable import FreoCore

final class ActiveCleaningTaskTests: XCTestCase {
    func testReplacementRequiresConfirmedIdleAndRecallsOnlyExplicitActiveTask() {
        let standby = RobotStatus(battery: 100, workingCode: 1)
        let running = RobotStatus(battery: 100, workingCode: 5)
        let empty = CleaningTaskSnapshot(resultCode: 2, mapID: nil, taskType: nil, optionFields: [:], samples: [])
        let active = CleaningTaskSnapshot(resultCode: 1, mapID: 17, taskType: 4, optionFields: [:],
                                          samples: [CleaningTaskSample(roomID: 3, parameters: [1: 4])])

        XCTAssertEqual(TaskReplacementPolicy.initial(status: standby, plan: empty), .ready)
        XCTAssertEqual(TaskReplacementPolicy.initial(status: running, plan: active), .recall)
        XCTAssertEqual(TaskReplacementPolicy.initial(status: running, plan: empty), .uncertain)
        XCTAssertEqual(TaskReplacementPolicy.initial(status: standby, plan: active), .recall)
        XCTAssertEqual(TaskReplacementPolicy.afterRecall(status: running, plan: active), .waiting)
        XCTAssertEqual(TaskReplacementPolicy.afterRecall(status: running, plan: empty), .waiting)
        XCTAssertEqual(TaskReplacementPolicy.afterRecall(status: standby, plan: empty), .ready)
        XCTAssertEqual(TaskReplacementPolicy.afterRecall(status: RobotStatus(battery: nil, workingCode: nil), plan: empty), .uncertain)
    }

    private let catalog = [RobotRoom(id: 3, name: "Hallway"), RobotRoom(id: 9, name: "Entry")]
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(_ samples: [CleaningTaskSample], result: Int = 1, map: Int? = 17) -> CleaningTaskSnapshot {
        .init(resultCode: result, mapID: map, taskType: 6, optionFields: [:], samples: samples)
    }

    func testTargetsComeFromTaskSamplesAndDeduplicateWhilePreservingReportedModes() throws {
        let task = plan([
            .init(roomID: 9, parameters: [1: 5]), .init(roomID: 3, parameters: [1: 2]),
            .init(roomID: 9, parameters: [1: 3]), .init(roomID: 3, parameters: [1: 4]),
            .init(roomID: 9, parameters: [1: 5])
        ])
        let result = try XCTUnwrap(CurrentCleaningTask.resolve(plan: task, rooms: catalog, mapID: 17))
        XCTAssertEqual(result.rooms, [catalog[1], catalog[0]])
        XCTAssertEqual(result.modeNames, ["Vacuum, then mop", "Vacuum", "Mop", "Vacuum & mop"])
        XCTAssertTrue(result.unresolvedRoomIDs.isEmpty)
        XCTAssertFalse(result.hasUnknownRoomTargets)
    }

    func testUnknownTargetsAndModesRemainExplicitWithoutInventingRoomNames() throws {
        let task = plan([.init(roomID: 99, parameters: [1: 912]), .init(roomID: 99, parameters: [:]),
                         .init(roomID: nil, parameters: [:])])
        let result = try XCTUnwrap(CurrentCleaningTask.resolve(plan: task, rooms: catalog, mapID: 17))
        XCTAssertTrue(result.rooms.isEmpty)
        XCTAssertEqual(result.unresolvedRoomIDs, [99])
        XCTAssertEqual(result.modeNames, ["Unknown mode (912)", "Unknown mode"])
        XCTAssertTrue(result.hasUnknownRoomTargets)
    }

    func testTaskRequiresSuccessfulMatchingMapAndUnambiguousCatalog() {
        let samples = [CleaningTaskSample(roomID: 9, parameters: [1: 2])]
        for task in [plan(samples, result: 0), plan(samples, map: nil), plan(samples, map: 18), plan([])] {
            XCTAssertNil(CurrentCleaningTask.resolve(plan: task, rooms: catalog, mapID: 17))
        }
        XCTAssertNil(CurrentCleaningTask.resolve(plan: plan(samples), rooms: catalog + [catalog[1]], mapID: 17))
        XCTAssertNil(CurrentCleaningTask.resolve(plan: plan(samples, map: 0), rooms: catalog, mapID: 0))
    }

    private func floorplan(revision: UInt32? = 41, pixels: [UInt32] = [0x901, 0x901, 0x301, 0x301]) -> Floorplan {
        .init(mapID: 17, width: 2, height: 2, resolution: 60, rooms: catalog, pixels: pixels, mapRevision: revision)
    }

    private func trajectory(point: RobotPathPoint? = .init(x: 0.5, y: 0.5),
                            capturedAge: Double = 0, deviceAge: Double? = 0,
                            map: Int = 17, revision: UInt32? = 41, simulated: Bool = false) -> RobotTrajectory {
        .init(productKey: "Synthetic", deviceID: "Synthetic", mapID: map, mapVersion: 110,
              editVersion: revision, points: [.init(x: 1.5, y: 1.5)], segments: [],
              pose: point.map(RobotPose.init(point:)), capturedAt: now.addingTimeInterval(-capturedAge),
              deviceTimestampMilliseconds: deviceAge.map { UInt64(now.addingTimeInterval(-$0).timeIntervalSince1970 * 1_000) },
              sequenceID: 1, isSimulated: simulated)
    }

    func testPositionUsesFreshPoseAndFlipsRasterRowsExactlyOnce() {
        XCTAssertEqual(CurrentCleaningTask.positionRoom(floorplan: floorplan(), trajectory: trajectory(), now: now), catalog[0])
        XCTAssertEqual(CurrentCleaningTask.positionRoom(floorplan: floorplan(),
            trajectory: trajectory(point: .init(x: 1.5, y: 1.5)), now: now), catalog[1])
        // The route tail points to Entry; it must not substitute for a missing pose.
        XCTAssertNil(CurrentCleaningTask.positionRoom(floorplan: floorplan(), trajectory: trajectory(point: nil), now: now))
    }

    func testPositionRejectsStaleMissingFutureAndMismatchedObservations() {
        for route in [trajectory(capturedAge: 30.001), trajectory(deviceAge: 30.001),
                      trajectory(capturedAge: -1), trajectory(deviceAge: -1), trajectory(deviceAge: nil),
                      trajectory(map: 18), trajectory(revision: 42), trajectory(revision: nil),
                      trajectory(simulated: true)] {
            XCTAssertNil(CurrentCleaningTask.positionRoom(floorplan: floorplan(), trajectory: route, now: now))
        }
        XCTAssertNotNil(CurrentCleaningTask.positionRoom(floorplan: floorplan(),
            trajectory: trajectory(capturedAge: 30, deviceAge: 30), now: now))
        XCTAssertNil(CurrentCleaningTask.positionRoom(floorplan: floorplan(revision: nil),
            trajectory: trajectory(revision: nil), now: now))
    }

    func testPositionRejectsOutsideInvalidAndUnassignedCellsWithoutClamping() {
        for point in [RobotPathPoint(x: -0.01, y: 0), .init(x: 0, y: -0.01), .init(x: 2, y: 0),
                      .init(x: 0, y: 2), .init(x: .nan, y: 0), .init(x: 0, y: .infinity)] {
            XCTAssertNil(CurrentCleaningTask.positionRoom(floorplan: floorplan(), trajectory: trajectory(point: point), now: now))
        }
        for pixels: [UInt32] in [[0x901], [0x901, 0x901, 0, 0], [0x901, 0x901, 0x6301, 0x6301]] {
            XCTAssertNil(CurrentCleaningTask.positionRoom(floorplan: floorplan(pixels: pixels), trajectory: trajectory(), now: now))
        }
    }
}
