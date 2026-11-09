import XCTest
@testable import FreoCore

final class ScheduleContextTests: XCTestCase {
    private let robot=RobotDevice(id:String(repeating:"a",count:32),productKey:"EHf6cRNRGT",name:"Synthetic robot")
    private let key="1ab8bd70-91d1-11ef-8b39-0242ac120002"
    private let zone=RobotTimezone(identifier:"America/Los_Angeles",queryTimezone:"UTC-8",offsetSeconds:-28800)
    private func snapshot(id:Int=7,main:Data=NarwalCodec.encodeNumber(30,1),pixel:UInt32=0x801,revision:UInt32=38) -> MapSnapshot {
        let map=Floorplan(mapID:id,width:1,height:1,resolution:60,rooms:[RobotRoom(id:8,name:"Kitchen")],pixels:[pixel],mapRevision:revision)
        return MapSnapshot(productKey:robot.productKey,deviceID:robot.id,mapID:id,mapVersion:110,editVersion:revision,capturedAt:Date(),floorplan:map,staticMapPayload:main)
    }
    private func context(map:MapSnapshot?=nil,timezone:RobotTimezone?=nil,entries:[ScheduleEntry]=[]) -> ScheduleContextSnapshot {
        ScheduleContextSnapshot(snapshot:ScheduleSnapshot(entries:entries,timezone:zone.identifier),map:map ?? snapshot(),timezone:timezone ?? zone,
            queryTimezone:zone.queryTimezone,primaryMapID:map?.mapID ?? 7,deviceID:robot.id,productKey:robot.productKey)
    }
    private func entry(enabled:Bool=true) throws -> ScheduleEntry {
        let draft=ScheduleDraft(name:"Kitchen",enabled:enabled,roomIDs:[8],mapID:7)
        let data=try NarwalScheduleCodec.createBody(draft:draft,device:robot,primaryMapID:7,knownRoomIDs:[8],key:key)
        let root=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let response=try JSONSerialization.data(withJSONObject:["code":0,"result":["scheduled_cleaning_tasks":root["scheduled_cleaning_tasks"]!]])
        return try XCTUnwrap(NarwalScheduleCodec.list(response,timezone:zone.identifier,primaryMapID:7).entries.first)
    }
    private func timezoneData(_ edits:[String:Any]=[:]) throws -> Data {
        var fields:[String:Any]=["device_id":robot.id,"product_id":robot.productKey,"timezone":"America/Los_Angeles","offset":"uninterpreted"]
        for(key,value)in edits {fields[key]=value}
        return try JSONSerialization.data(withJSONObject:["code":0,"result":fields])
    }

    func testPrimaryMapRequiresExplicitTrueFlagNotMapIDOne() throws {
        XCTAssertEqual(try RobotScheduleContext.primaryMapID(snapshot()),7)
        XCTAssertNil(try RobotScheduleContext.primaryMapID(snapshot(id:1,main:Data())))
        XCTAssertNil(try RobotScheduleContext.primaryMapID(snapshot(main:NarwalCodec.encodeNumber(30,0))))
        for bad in [NarwalCodec.encodeNumber(30,2),NarwalCodec.encodeBytes(30,Data()),NarwalCodec.encodeNumber(30,1)+NarwalCodec.encodeNumber(30,1)] {
            XCTAssertThrowsError(try RobotScheduleContext.primaryMapID(snapshot(main:bad)))
        }
    }
    func testTimezoneRequiresMatchingRobotAndRealIANAZone() throws {
        XCTAssertThrowsError(try RobotScheduleContext.timezone(timezoneData(["device_id":String(repeating:"b",count:32)]),device:robot))
        XCTAssertThrowsError(try RobotScheduleContext.timezone(timezoneData(["product_id":"other"]),device:robot))
        XCTAssertThrowsError(try RobotScheduleContext.timezone(timezoneData(["timezone":"UTC-8"]),device:robot))
        XCTAssertThrowsError(try RobotScheduleContext.timezone(timezoneData(["timezone":"America/Unknown"]),device:robot))
        XCTAssertThrowsError(try RobotScheduleContext.timezone(timezoneData(["timezone":"Asia/Kolkata"]),device:robot))
    }
    func testTimezoneUsesDateSpecificDSTRatherThanUnprovenOffsetField() throws {
        let formatter=ISO8601DateFormatter()
        let winter=try RobotScheduleContext.timezone(timezoneData(),device:robot,now:XCTUnwrap(formatter.date(from:"2026-01-15T12:00:00Z")))
        let summer=try RobotScheduleContext.timezone(timezoneData(),device:robot,now:XCTUnwrap(formatter.date(from:"2026-07-15T12:00:00Z")))
        XCTAssertEqual(winter.queryTimezone,"UTC-8"); XCTAssertEqual(summer.queryTimezone,"UTC-7")
        XCTAssertNotEqual(winter,summer)
    }
    func testViewFallbackNeverCreatesWriteAuthority() {
        let value=ScheduleContextSnapshot(snapshot:ScheduleSnapshot(entries:[]),map:snapshot(),timezone:nil,queryTimezone:"UTC-8",primaryMapID:7,deviceID:robot.id,productKey:robot.productKey)
        XCTAssertNotNil(value.writeUnavailableReason)
        let other=ScheduleContextSnapshot(snapshot:ScheduleSnapshot(entries:[]),map:snapshot(),timezone:zone,queryTimezone:"UTC-8",primaryMapID:nil,deviceID:robot.id,productKey:robot.productKey)
        XCTAssertNotNil(other.writeUnavailableReason)
    }
    func testConcurrentMapRevisionTimezoneAndRoomGeometryChangesReject() throws {
        let old=context()
        XCTAssertThrowsError(try RobotScheduleContext.validate(expected:old,fresh:context(map:snapshot(revision:39)),device:robot))
        XCTAssertThrowsError(try RobotScheduleContext.validate(expected:old,fresh:context(map:snapshot(pixel:0x301)),device:robot))
        XCTAssertThrowsError(try RobotScheduleContext.validate(expected:old,fresh:context(timezone:RobotTimezone(identifier:zone.identifier,queryTimezone:"UTC-7",offsetSeconds:-25200)),device:robot))
    }
    func testRuntimeBitsDoNotInventAChangedRoomButOtherFlagsRemainExact() throws {
        let old=context()
        XCTAssertNoThrow(try RobotScheduleContext.validate(expected:old,fresh:context(map:snapshot(pixel:0x801 ^ 0x1001_0043)),device:robot))
        XCTAssertNoThrow(try RobotScheduleContext.validate(expected:old,fresh:context(map:snapshot(pixel:0x801 ^ 0x40)),device:robot))
        for flag:UInt32 in [0x10,0x20,0x100,0x40000000] {
            XCTAssertThrowsError(try RobotScheduleContext.validate(expected:old,fresh:context(map:snapshot(pixel:0x801 ^ flag)),device:robot))
        }
    }
    func testConcurrentScheduleEditOrDeletionRejectsBeforeSend() throws {
        let old=try entry(), changed=try entry(enabled:false)
        XCTAssertThrowsError(try RobotScheduleContext.currentEntry(old,in:context(entries:[changed])))
        XCTAssertThrowsError(try RobotScheduleContext.currentEntry(old,in:context(entries:[])))
        XCTAssertEqual(try RobotScheduleContext.currentEntry(old,in:context(entries:[old])).id,key)
    }
    func testUnknownOutcomeDoesNotRetryPOSTOrReadback() async throws {
        var sends=0,reads=0
        do {
            _ = try await RobotScheduleContext.commit(send:{sends+=1;return Data("{\"code\":0}".utf8)},readBack:{reads+=1;throw ConnectorError.invalid("offline")},verify:{_ in})
            XCTFail("Expected uncertainty")
        } catch ScheduleWriteError.outcomeUnknown {} catch {XCTFail("Wrong error: \(error)")}
        XCTAssertEqual(sends,1);XCTAssertEqual(reads,1)
        sends=0;reads=0
        do {
            _ = try await RobotScheduleContext.commit(send:{sends+=1;throw CancellationError()},readBack:{reads+=1;return self.context()},verify:{_ in})
            XCTFail("Expected uncertainty")
        } catch ScheduleWriteError.outcomeUnknown {} catch {XCTFail("Wrong error: \(error)")}
        XCTAssertEqual(sends,1);XCTAssertEqual(reads,0)
    }
    func testAcceptedButWrongReadbackIsUnknownAndUnrelatedSchedulesAreProtected() async throws {
        let old=try entry(), changed=try entry(enabled:false)
        XCTAssertThrowsError(try RobotScheduleContext.validateUnchangedSchedules(before:context(entries:[old]),after:context(entries:[changed]),changedKey:"another-key"))
        XCTAssertThrowsError(try RobotScheduleContext.validateUnchangedSchedules(before:context(entries:[old]),after:context(entries:[]),changedKey:"another-key"))
        var sends=0
        do {
            _ = try await RobotScheduleContext.commit(send:{sends+=1;return Data("{\"code\":0}".utf8)},readBack:{self.context()},verify:{_ in throw ConnectorError.invalid("mismatch")})
            XCTFail("Expected uncertainty")
        } catch ScheduleWriteError.outcomeUnknown {} catch {XCTFail("Wrong error: \(error)")}
        XCTAssertEqual(sends,1)
    }
}
