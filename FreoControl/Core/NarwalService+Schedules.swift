import Foundation

extension NarwalService {
    public func schedules(device: RobotDevice) async throws -> ScheduleContextSnapshot {
        try begin(); defer { busy=false }
        try validate(device); let current=generation
        let context=try await readScheduleContext(device:device,generation:current)
        try check(current)
        // Only an explicit successful refresh clears an uncertain-write latch.
        scheduleUncertainDevices.remove(device.id)
        return context
    }

    public func saveSchedule(device: RobotDevice, draft: ScheduleDraft, existing: ScheduleEntry?, expectedContext: ScheduleContextSnapshot) async throws -> ScheduleContextSnapshot {
        try begin(); defer { busy=false }
        try validate(device); try requireScheduleReady(device)
        let current=generation
        let fresh=try await readScheduleContext(device:device,generation:current)
        try RobotScheduleContext.validate(expected:expectedContext,fresh:fresh,device:device)
        guard let primary=fresh.primaryMapID else { throw ConnectorError.invalid("Verify the primary map before saving a schedule.") }
        let key:String, body:Data
        if let existing {
            let actual=try RobotScheduleContext.currentEntry(existing,in:fresh)
            key=actual.id
            body=try NarwalScheduleCodec.updateBody(entry:actual,draft:draft,device:device,primaryMapID:primary)
        } else {
            guard fresh.snapshot.entries.count < 100 else { throw ConnectorError.invalid("The schedule list is full.") }
            key=try NarwalScheduleCodec.newKey()
            guard !fresh.snapshot.entries.contains(where:{$0.id==key}) else { throw ConnectorError.invalid("The schedule identifier collided. Review and save again.") }
            body=try NarwalScheduleCodec.createBody(draft:draft,device:device,primaryMapID:primary,knownRoomIDs:fresh.roomIDs,key:key)
        }
        return try await commitSchedule(device:device,generation:current,before:fresh,key:key,
            request:ScheduleRequest(method:"POST",path:NarwalScheduleCodec.additionalPath,body:body),expectedBody:body)
    }

    public func setScheduleEnabled(device: RobotDevice, entry: ScheduleEntry, enabled: Bool, expectedContext: ScheduleContextSnapshot) async throws -> ScheduleContextSnapshot {
        try begin(); defer { busy=false }
        try validate(device); try requireScheduleReady(device)
        let current=generation
        let fresh=try await readScheduleContext(device:device,generation:current)
        try RobotScheduleContext.validate(expected:expectedContext,fresh:fresh,device:device)
        let actual=try RobotScheduleContext.currentEntry(entry,in:fresh)
        guard let primary=fresh.primaryMapID else { throw ConnectorError.invalid("Verify the primary map before changing a schedule.") }
        let body=try NarwalScheduleCodec.setEnabledBody(entry:actual,enabled:enabled,device:device,primaryMapID:primary)
        return try await commitSchedule(device:device,generation:current,before:fresh,key:actual.id,
            request:ScheduleRequest(method:"POST",path:NarwalScheduleCodec.additionalPath,body:body),expectedBody:body)
    }

    public func deleteSchedule(device: RobotDevice, entry: ScheduleEntry, expectedContext: ScheduleContextSnapshot) async throws -> ScheduleContextSnapshot {
        try begin(); defer { busy=false }
        try validate(device); try requireScheduleReady(device)
        let current=generation
        let fresh=try await readScheduleContext(device:device,generation:current)
        try RobotScheduleContext.validate(expected:expectedContext,fresh:fresh,device:device)
        let actual=try RobotScheduleContext.currentEntry(entry,in:fresh)
        return try await commitSchedule(device:device,generation:current,before:fresh,key:actual.id,
            request:NarwalScheduleCodec.delete(entry:actual,device:device),expectedBody:nil)
    }

    private func readScheduleContext(device: RobotDevice, generation current: Int) async throws -> ScheduleContextSnapshot {
        try check(current); try validate(device)
        var zone:RobotTimezone?, map:MapSnapshot?, primary:Int?
        do {
            let access=try await accessToken(current)
            let request=try RobotScheduleContext.timezoneRequest(device:device)
            let raw=try await requestData(path:request.path,method:request.method,body:nil,token:access.token)
            try check(current)
            zone=try RobotScheduleContext.timezone(raw,device:device)
        } catch {
            // An unavailable timezone does not erase the read-only schedule list.
            try check(current); try validate(device)
        }
        do {
            let raw=try await query(device,topic:"map/get_map")
            try check(current)
            let value=try NarwalCodec.mapSnapshot(raw,device:device)
            primary=try RobotScheduleContext.primaryMapID(value)
            map=value
        } catch {
            try check(current); try validate(device)
        }
        let queryZone=zone?.queryTimezone ?? RobotScheduleContext.viewQueryTimezone()
        let listRequest=try NarwalScheduleCodec.listRequest(device:device,timezone:queryZone)
        let access=try await accessToken(current)
        let raw=try await requestData(path:listRequest.path,method:listRequest.method,body:nil,token:access.token)
        try check(current); try validate(device)
        let snapshot=try NarwalScheduleCodec.list(raw,timezone:zone?.identifier,primaryMapID:primary)
        return ScheduleContextSnapshot(snapshot:snapshot,map:map,timezone:zone,queryTimezone:queryZone,
            primaryMapID:primary,deviceID:device.id,productKey:device.productKey)
    }

    private func requireScheduleReady(_ device:RobotDevice) throws {
        guard device.canControl else { throw ConnectorError.invalid("Schedules for this robot model are read-only.") }
        guard !scheduleUncertainDevices.contains(device.id) else { throw ScheduleWriteError.outcomeUnknown }
    }

    private func commitSchedule(device:RobotDevice,generation current:Int,before:ScheduleContextSnapshot,key:String,
                                request:ScheduleRequest,expectedBody:Data?) async throws -> ScheduleContextSnapshot {
        let access=try await accessToken(current)
        try check(current); try validate(device)
        do {
            return try await RobotScheduleContext.commit(send: {
                try self.check(current); try self.validate(device)
                let response=try await self.requestData(path:request.path,method:request.method,body:request.body,token:access.token)
                try self.check(current)
                return response
            },readBack: {
                try self.check(current)
                return try await self.readScheduleContext(device:device,generation:current)
            },verify: { after in
                try RobotScheduleContext.validate(expected:before,fresh:after,device:device)
                try RobotScheduleContext.validateUnchangedSchedules(before:before,after:after,changedKey:key)
                if let expectedBody { try NarwalScheduleCodec.validateReadback(expectedBody:expectedBody,current:after.snapshot) }
                else if after.snapshot.entries.contains(where:{$0.id==key}) { throw ScheduleWriteError.outcomeUnknown }
            })
        } catch {
            // A disconnected old generation must not mark a newly signed-in
            // account uncertain. Its caller still receives an unknown outcome.
            if current == generation { scheduleUncertainDevices.insert(device.id) }
            throw ScheduleWriteError.outcomeUnknown
        }
    }
}
