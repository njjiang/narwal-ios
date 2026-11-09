import XCTest
@testable import FreoCore

final class ScheduleTests: XCTestCase {
    private let device = RobotDevice(id: "0123456789abcdef0123456789abcdef", productKey: "EHf6cRNRGT", name: "Synthetic robot")
    private let key = "1ab8bd70-91d1-11ef-8b39-0242ac120002"
    private func raw(mode: Any = "CLEAN_MODE_SWEEP", map: Int = 1, zoneType: Any = "ZONE_TYPE_ROOM") -> [String:Any] {
        ["cron":"0 30 9 ? * MON,WED,FRI", "enable":true, "triggerType":"SCHEDULE_TRIGGER_TYPE_CRON",
         "futureSetting":["exactInteger": NSNumber(value: Int64(9007199254740993)), "nested":["keep":true]],
         "task":["mapId":map,"taskType":"TASK_TYPE_SCHEDULED","option":["unknownOption":17],
                 "items":[["zone":["zoneType":zoneType,"zoneId":8],"param":["mode":mode,"fanLevel":2,"sweepTime":1,"unknownParameter":91],"order":1]]]]
    }
    private func encode(_ value:[String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:.sortedKeys) }
    private func list(_ value:[String:Any]) throws -> ScheduleSnapshot {
        try NarwalScheduleCodec.list(encode(["code":0,"result":["scheduled_cleaning_tasks":[key:value]]]),timezone:"America/Los_Angeles",primaryMapID:1)
    }
    private func object(_ data:Data) throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]) }
    private func updatedValue(_ body:Data) throws -> [String:Any] {
        let tasks = try XCTUnwrap(try object(body)["scheduled_cleaning_tasks"] as? [String:Any])
        return try XCTUnwrap(tasks[key] as? [String:Any])
    }

    func testWeeklyNamedAndNumericDaysUseExplicitSundayMapping() throws {
        let a = try XCTUnwrap(NarwalScheduleCodec.parseWeeklyCron("0 7 23 ? * 1,2,7"))
        XCTAssertEqual(a.hour,23); XCTAssertEqual(a.minute,7); XCTAssertEqual(a.weekdays,[1,6,7])
        XCTAssertEqual(try NarwalScheduleCodec.weeklyCron(hour:23,minute:7,weekdays:[7,1,6]),"0 7 23 ? * MON,SAT,SUN")
    }
    func testUnsupportedCronNeverCoercedIntoWeekly() {
        for value in ["*/10 * * * * ?","0 0 9 3 11 ? 2026","0 0 9 ? * MON-FRI","0 0 9 ? * MON,2","0 0 24 ? * MON","0 60 9 ? * MON","0 0 9 ? * MON,"] {
            XCTAssertNil(NarwalScheduleCodec.parseWeeklyCron(value),value)
        }
        XCTAssertThrowsError(try NarwalScheduleCodec.weeklyCron(hour:9,minute:0,weekdays:[]))
        XCTAssertThrowsError(try NarwalScheduleCodec.weeklyCron(hour:9,minute:0,weekdays:[1,1]))
    }
    func testListIsScopedToPrimaryMapAndRooms() throws {
        let entry = try XCTUnwrap(try list(raw()).entries.first)
        XCTAssertEqual(entry.roomIDs,[8]); XCTAssertEqual(entry.mapID,1); XCTAssertEqual(entry.mode,.vacuum)
        XCTAssertEqual(entry.weekdays,[1,3,5]); XCTAssertTrue(entry.canEdit); XCTAssertEqual(entry.enabled,true)
        XCTAssertFalse(try XCTUnwrap(list(raw(map:2)).entries.first).canEdit)
        XCTAssertFalse(try XCTUnwrap(list(raw(zoneType:2)).entries.first).canEdit)
    }
    func testFourModesRecognizedWithoutGuessingTaskType() throws {
        for (code,mode) in [(2,CleaningMode.vacuum),(3,.mop),(4,.vacuumMop),(5,.vacuumThenMop)] {
            XCTAssertEqual(try list(raw(mode:code)).entries.first?.mode,mode)
        }
    }
    func testTimeEditPreservesEveryTaskAndUnknownFieldIncludingLargeInteger() throws {
        let entry = try XCTUnwrap(list(raw()).entries.first)
        var draft=ScheduleDraft(entry:entry); draft.hour=18; draft.minute=45; draft.weekdays=[6,7]; draft.enabled=false
        let updated = try updatedValue(NarwalScheduleCodec.updateBody(entry:entry,draft:draft,device:device,primaryMapID:1))
        var expected=raw(); expected["cron"]="0 45 18 ? * SAT,SUN"; expected["enable"]=false
        XCTAssertTrue(NSDictionary(dictionary:updated).isEqual(to:expected))
        let future = try XCTUnwrap(updated["futureSetting"] as? [String:Any])
        XCTAssertEqual((future["exactInteger"] as? NSNumber)?.int64Value,9007199254740993)
    }
    func testEnablePreservesCronAndCompleteTask() throws {
        let entry=try XCTUnwrap(list(raw()).entries.first)
        var expected=raw(); expected["enable"]=false
        XCTAssertTrue(NSDictionary(dictionary:try updatedValue(NarwalScheduleCodec.setEnabledBody(entry:entry,enabled:false,device:device,primaryMapID:1))).isEqual(to:expected))
    }
    func testEditorCannotChangeCleaningScope() throws {
        let entry=try XCTUnwrap(list(raw()).entries.first)
        var draft=ScheduleDraft(entry:entry); draft.roomIDs=[3,8]
        XCTAssertThrowsError(try NarwalScheduleCodec.updateBody(entry:entry,draft:draft,device:device,primaryMapID:1))
        XCTAssertThrowsError(try NarwalScheduleCodec.setEnabledBody(entry:entry,enabled:true,device:device,primaryMapID:2))
    }
    func testIntervalsAndExceptionDatesRemainReadOnly() throws {
        var value=raw(); value["triggerType"]="SCHEDULE_TRIGGER_TYPE_CYCLE"
        XCTAssertFalse(try XCTUnwrap(list(value).entries.first).canEdit)
        value=raw(); value["disabledCron"]=["0 30 9 4 11 ? 2026"]
        let entry=try XCTUnwrap(list(value).entries.first); XCTAssertFalse(entry.canEdit)
        XCTAssertThrowsError(try NarwalScheduleCodec.setEnabledBody(entry:entry,enabled:true,device:device,primaryMapID:1))
    }
    func testExplicitDeleteUsesExactKeyAndSnakeCaseScope() throws {
        let entry=try XCTUnwrap(list(raw()).entries.first), request=try NarwalScheduleCodec.delete(entry:entry,device:device)
        XCTAssertEqual(request.method,"POST"); XCTAssertEqual(request.path,"/device-task/scheduled-task/sweeper/deleteEntry")
        let body=try object(XCTUnwrap(request.body))
        XCTAssertEqual(Set(body.keys),["device_id","product_id","scheduled_cleaning_tasks_key"])
        XCTAssertEqual(body["scheduled_cleaning_tasks_key"] as? String,key)
    }
    func testListQueryEscapesOffsetPlusAndRejectsMalformedScope() throws {
        let request=try NarwalScheduleCodec.listRequest(device:device,timezone:"UTC+3")
        XCTAssertEqual(request.method,"GET")
        let components=try XCTUnwrap(URLComponents(string:request.path))
        XCTAssertEqual(components.queryItems?.first(where:{$0.name=="timezone"})?.value,"UTC+3")
        XCTAssertThrowsError(try NarwalScheduleCodec.listRequest(device:device,timezone:"America/Los_Angeles"))
        XCTAssertThrowsError(try NarwalScheduleCodec.listRequest(device:RobotDevice(id:"a&other=b",productKey:device.productKey,name:"bad"),timezone:"UTC-8"))
    }
    func testBooleanCodeAndMissingListFailClosed() throws {
        XCTAssertThrowsError(try NarwalScheduleCodec.list(encode(["code":false,"result":["scheduled_cleaning_tasks":[:]]])))
        XCTAssertThrowsError(try NarwalScheduleCodec.list(encode(["code":0,"result":[:]])))
        XCTAssertThrowsError(try NarwalScheduleCodec.list(encode(["code":0,"result":["scheduled_cleaning_tasks":[]]])))
        XCTAssertThrowsError(try NarwalScheduleCodec.acknowledgement(encode(["code":false])))
        XCTAssertThrowsError(try NarwalScheduleCodec.acknowledgement(encode(["code":"0"])))
    }
    func testConflictingAliasesAndBooleanIDsRejected() throws {
        var value=raw(); value["trigger_type"]=1
        XCTAssertThrowsError(try list(value))
        value=raw(); var task=try XCTUnwrap(value["task"] as? [String:Any]); task["mapId"]=true; value["task"]=task
        XCTAssertThrowsError(try list(value))
    }
    func testReadbackMustPreserveExactUnknownSettings() throws {
        let entry=try XCTUnwrap(list(raw()).entries.first), body=try NarwalScheduleCodec.setEnabledBody(entry:entry,enabled:false,device:device,primaryMapID:1)
        var expected=raw(); expected["enable"]=false
        XCTAssertNoThrow(try NarwalScheduleCodec.validateReadback(expectedBody:body,current:list(expected)))
        expected["futureSetting"]=["lost":true]
        XCTAssertThrowsError(try NarwalScheduleCodec.validateReadback(expectedBody:body,current:list(expected)))
    }
    func testReadbackDoesNotTreatUnknownBooleanAsInteger() throws {
        var value=raw(); value["futureFlag"]=true
        let entry=try XCTUnwrap(list(value).entries.first), body=try NarwalScheduleCodec.setEnabledBody(entry:entry,enabled:false,device:device,primaryMapID:1)
        value["enable"]=false; value["futureFlag"]=1
        XCTAssertThrowsError(try NarwalScheduleCodec.validateReadback(expectedBody:body,current:list(value)))
    }
    func testDisabledReadbackMayOmitKnownProto3FalseOnly() throws {
        let entry=try XCTUnwrap(list(raw()).entries.first), body=try NarwalScheduleCodec.setEnabledBody(entry:entry,enabled:false,device:device,primaryMapID:1)
        var value=raw(); value.removeValue(forKey:"enable")
        XCTAssertNoThrow(try NarwalScheduleCodec.validateReadback(expectedBody:body,current:list(value)))
        value["enable"]=0
        XCTAssertThrowsError(try NarwalScheduleCodec.validateReadback(expectedBody:body,current:list(value)))
    }
    func testBoundsRejectBeforeRecursiveJSONParsing() throws {
        XCTAssertThrowsError(try NarwalScheduleCodec.list(Data(repeating:32,count:1024*1024+1)))
        let deep=Data((String(repeating:"{\"a\":",count:25)+"0"+String(repeating:"}",count:25)).utf8)
        XCTAssertThrowsError(try NarwalScheduleCodec.list(deep))
    }
    func testUnknownEnumsRemainVisibleAndReadOnly() throws {
        var value=raw(mode:"CLEAN_MODE_FUTURE")
        XCTAssertFalse(try XCTUnwrap(list(value).entries.first).canEdit)
        value=raw(); value["triggerType"]="SCHEDULE_TRIGGER_TYPE_FUTURE"
        XCTAssertFalse(try XCTUnwrap(list(value).entries.first).canEdit)
    }
    func testTimeEditUpdatesOnlyRecognizedExtraCron() throws {
        var value=raw(), task=try XCTUnwrap(raw()["task"] as? [String:Any])
        let metadata:[String:Any] = ["cron":value["cron"]!,"task":["sweeper_scheme_task":["taskName":"Kitchen mornings"],"created_at":1234],"unknown":77]
        task["extra"]=String(decoding:try encode(metadata),as:UTF8.self); value["task"]=task
        let entry=try XCTUnwrap(list(value).entries.first); XCTAssertEqual(entry.name,"Kitchen mornings")
        var draft=ScheduleDraft(entry:entry); draft.hour=10
        let updated=try updatedValue(NarwalScheduleCodec.updateBody(entry:entry,draft:draft,device:device,primaryMapID:1))
        let updatedTask=try XCTUnwrap(updated["task"] as? [String:Any]), extra=try XCTUnwrap(updatedTask["extra"] as? String)
        var expected=metadata; expected["cron"]="0 30 10 ? * MON,WED,FRI"
        XCTAssertTrue(NSDictionary(dictionary:try object(Data(extra.utf8))).isEqual(to:expected))
    }
    func testNewKeyHasVersionOneVariantAndExactTimestampWithoutHardwareNode() throws {
        let now=Date(timeIntervalSince1970:1_700_000_000.125)
        let entropy=try XCTUnwrap(UUID(uuidString:"11111111-2222-4333-8444-005566778899"))
        let key=try NarwalScheduleCodec.newKey(now:now,entropy:entropy), uuid=try XCTUnwrap(UUID(uuidString:key)).uuid
        XCTAssertEqual(uuid.6 >> 4,1); XCTAssertEqual(uuid.8 & 0xc0,0x80); XCTAssertEqual(uuid.10 & 1,1)
        let ticks = UInt64(uuid.0) << 24 | UInt64(uuid.1) << 16 | UInt64(uuid.2) << 8 | UInt64(uuid.3)
            | UInt64(uuid.4) << 40 | UInt64(uuid.5) << 32 | UInt64(uuid.6 & 15) << 56 | UInt64(uuid.7) << 48
        XCTAssertEqual(ticks,1_700_000_000_125 * 10_000 + 0x01b21dd213814000)
        XCTAssertThrowsError(try NarwalScheduleCodec.newKey(now:Date(timeIntervalSince1970:.infinity)))
    }
    func testCreateAllModesUsesOnlySelectedPrimaryRoomsAndScheduledTaskType() throws {
        for mode in CleaningMode.allCases {
            let draft=ScheduleDraft(name:"Kitchen",enabled:false,hour:12,minute:10,weekdays:[2,4],mode:mode,roomIDs:[8],mapID:1)
            let body=try NarwalScheduleCodec.createBody(draft:draft,device:device,primaryMapID:1,knownRoomIDs:[3,8],key:key,now:Date(timeIntervalSince1970:1_700_000_000))
            let value=try updatedValue(body), task=try XCTUnwrap(value["task"] as? [String:Any])
            XCTAssertEqual(task["taskType"] as? String,"TASK_TYPE_SCHEDULED")
            XCTAssertEqual((task["items"] as? [[String:Any]])?.count,1)
            let entry=try XCTUnwrap(list(value).entries.first)
            XCTAssertEqual(entry.roomIDs,[8]); XCTAssertEqual(entry.mode,mode); XCTAssertEqual(entry.name,"Kitchen")
            XCTAssertEqual(entry.enabled,false); XCTAssertEqual(entry.weekdays,[2,4])
            let metadata=try object(Data(try XCTUnwrap(task["extra"] as? String).utf8))
            let model=try XCTUnwrap(metadata["task"] as? [String:Any]), scheme=try XCTUnwrap(model["sweeper_scheme_task"] as? [String:Any])
            XCTAssertNil(scheme["cleanTask"]); XCTAssertEqual((model["created_at"] as? NSNumber)?.int64Value,1_700_000_000_000)
        }
    }
    func testCreateRejectsStaleRoomUnknownMapAndRegeneratedWrongVersionKey() throws {
        let draft=ScheduleDraft(roomIDs:[8],mapID:1)
        XCTAssertThrowsError(try NarwalScheduleCodec.createBody(draft:draft,device:device,primaryMapID:2,knownRoomIDs:[8],key:key))
        XCTAssertThrowsError(try NarwalScheduleCodec.createBody(draft:draft,device:device,primaryMapID:1,knownRoomIDs:[3],key:key))
        XCTAssertThrowsError(try NarwalScheduleCodec.createBody(draft:draft,device:device,primaryMapID:1,knownRoomIDs:[8],key:UUID().uuidString))
    }
}
