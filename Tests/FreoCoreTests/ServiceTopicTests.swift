import Foundation
import XCTest
@testable import FreoCore

final class ServiceTopicTests: XCTestCase {
    private let uuid = "00112233445566778899aabbccddeeff"
    private let device = RobotDevice(id: "ffeeddccbbaa99887766554433221100", productKey: "EHf6cRNRGT", name: "Offline test")

    private func session(device: RobotDevice, suffix: String, command: Bool) throws -> MQTTSession {
        try MQTTSession(uuid: uuid, token: "offline-test-token", device: device,
                        topic: NarwalService.mqttTopic(device: device, suffix: suffix),
                        payload: Data([1]), correlation: Data([2]), isCommand: command)
    }

    func testProductionHelperBuildsEveryAllowlistedDeviceTopic() throws {
        let reads = ["status/get_device_base_status", "map/get_map", "map/get_editable_map", "clean/current_clean_task/get"]
        let commands = ["task/pause", "task/resume", "supply/recall", "clean/start_clean", "map/operation"]
        for suffix in reads + commands {
            let full = NarwalService.mqttTopic(device: device, suffix: suffix)
            XCTAssertEqual(full, "/EHf6cRNRGT/ffeeddccbbaa99887766554433221100/\(suffix)")
            var state = try session(device: device, suffix: suffix, command: commands.contains(suffix))
            _ = try state.receive(MQTTFrame(header: 0x20, body: Data([0, 0, 0])))
            let publication = try state.receive(MQTTFrame(header: 0x90, body: Data([0, 1, 0, 0])))
            var decoder = MQTTFrameDecoder()
            let frames = try decoder.append(publication[0])
            XCTAssertEqual(try MQTTCodec.decodePublish(frames[0]).topic, full)
        }
    }

    func testTopicHelperDoesNotBypassReadCommandSeparationOrSuffixValidation() throws {
        XCTAssertThrowsError(try session(device: device, suffix: "task/pause", command: false))
        XCTAssertThrowsError(try session(device: device, suffix: "map/get_map", command: true))
        XCTAssertThrowsError(try session(device: device, suffix: "map/get_editable_map", command: true))
        XCTAssertThrowsError(try session(device: device, suffix: "map/operation", command: false))
        for suffix in ["", "/task/pause", "task/force_end", "config/set", "clean/plan/start",
                       "task/pause/response", "task/../pause", "task/pause\n", "#",
                       "/other/ffeeddccbbaa99887766554433221100/task/pause"] {
            XCTAssertThrowsError(try session(device: device, suffix: suffix, command: true))
        }
    }

    func testInvalidDeviceScopeStillFailsStrictMQTTValidation() throws {
        let invalid = [
            RobotDevice(id: "123", productKey: "EHf6cRNRGT", name: "Invalid ID"),
            RobotDevice(id: device.id, productKey: "other/robot", name: "Injected namespace"),
            RobotDevice(id: device.id + "/task/pause", productKey: device.productKey, name: "Injected ID"),
            RobotDevice(id: device.id, productKey: "", name: "Missing product")
        ]
        for robot in invalid { XCTAssertThrowsError(try session(device: robot, suffix: "task/pause", command: true)) }
        let other = RobotDevice(id: "00112233445566778899aabbccddeeff", productKey: device.productKey, name: "Other device")
        XCTAssertThrowsError(try MQTTSession(uuid: uuid, token: "offline-test-token", device: device,
                                            topic: NarwalService.mqttTopic(device: other, suffix: "task/pause"),
                                            payload: Data([1]), correlation: Data([2]), isCommand: true))
    }
}
