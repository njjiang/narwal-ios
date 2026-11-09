import Foundation

@MainActor
extension FreoStore {
    var scheduleWriteUnavailableReason: String? {
        if isDemo { return nil }
        guard isAuthenticated, selectedDevice != nil else { return "Connect your robot to change schedules." }
        if scheduleWriteUncertain { return "A schedule request could not be verified. Refresh and review the saved schedules before changing them again." }
        guard let context = scheduleContext,
              context.deviceID == selectedDeviceID,
              context.productKey == selectedDevice?.productKey else { return "Refresh schedules before making changes." }
        if let reason = context.writeUnavailableReason { return reason }
        guard context.snapshot.fetchedAt.timeIntervalSinceNow > -300 else { return "Refresh schedules to check the latest settings." }
        return nil
    }

    var scheduleCreateUnavailableReason: String? {
        if let reason = scheduleWriteUnavailableReason { return reason }
        guard !rooms.isEmpty else { return "Load rooms from the main map before creating a schedule." }
        if !isDemo {
            guard let context = scheduleContext, context.primaryMapID == floorplan?.mapID,
                  context.roomIDs == Set(rooms.map(\.id)) else { return "Refresh schedules to load the current main-map rooms." }
            guard (scheduleSnapshot?.entries.count ?? 100) < 100 else { return "The schedule list is full." }
        }
        return nil
    }

    /// Invalidates in-flight presentation and prevents demo/device/map changes
    /// from carrying a previous robot's schedule into the next session.
    func resetSchedules() {
        scheduleScope = UUID()
        scheduleSnapshot = nil; scheduleContext = nil; scheduleError = ""
        scheduleWriteUncertain = false
    }

    func loadSchedules() async {
        guard !isBusy, !isSchedulesLoading else { return }
        if isDemo {
            if scheduleSnapshot == nil { scheduleSnapshot = ScheduleSnapshot(entries: [], timezone: "Demo clock") }
            scheduleError = ""
            return
        }
        guard isAuthenticated, let robot = selectedDevice else {
            scheduleError = "Connect your robot to read its schedules."
            return
        }
        let scope = scheduleScope
        isBusy = true; isSchedulesLoading = true
        defer { isBusy = false; isSchedulesLoading = false }
        await awaitLiveRequestSlot()
        do {
            let context = try await service.schedules(device: robot)
            guard scheduleScope == scope, isAuthenticated, !isDemo,
                  selectedDevice == robot else { return }
            acceptSchedules(context)
            scheduleWriteUncertain = false; scheduleError = ""
        } catch {
            guard scheduleScope == scope else { return }
            scheduleError = error.localizedDescription
            // Keep the last list visible, but do not let it authorize a write
            // after a refresh failed or the session expired.
            scheduleContext = nil
            if await service.sessionExpiration() == nil { clearPresentation() }
        }
    }

    func saveSchedule(draft: ScheduleDraft, existing: ScheduleEntry?) async -> Bool {
        if let reason = existing == nil ? scheduleCreateUnavailableReason : scheduleWriteUnavailableReason {
            scheduleError = reason; return false
        }
        guard !isBusy else { return false }
        if isDemo {
            do {
                _ = try NarwalScheduleCodec.weeklyCron(hour: draft.hour, minute: draft.minute, weekdays: draft.weekdays)
                guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      draft.name.count <= 64, !draft.roomIDs.isEmpty,
                      draft.mapID == floorplan?.mapID,
                      Set(draft.roomIDs).isSubset(of: Set(rooms.map(\.id))) else {
                    throw ConnectorError.invalid("Choose a name and rooms for this demo schedule.")
                }
                var entries = scheduleSnapshot?.entries ?? []
                if let existing {
                    guard let index = entries.firstIndex(where: { $0.id == existing.id }) else { throw ConnectorError.invalid("This demo schedule was removed.") }
                    entries[index] = try demoSchedule(draft, id: existing.id)
                } else { entries.append(try demoSchedule(draft, id: UUID().uuidString)) }
                scheduleSnapshot = ScheduleSnapshot(entries: entries, timezone: "Demo clock")
                scheduleError = ""; return true
            } catch { scheduleError = error.localizedDescription; return false }
        }
        return await mutateSchedule { robot, context in
            try await self.service.saveSchedule(device: robot, draft: draft, existing: existing, expectedContext: context)
        }
    }

    func setScheduleEnabled(_ entry: ScheduleEntry, enabled: Bool) async -> Bool {
        guard !isBusy else { return false }
        if let reason = scheduleWriteUnavailableReason { scheduleError = reason; return false }
        if isDemo {
            var draft = ScheduleDraft(entry: entry); draft.enabled = enabled
            return await saveSchedule(draft: draft, existing: entry)
        }
        return await mutateSchedule { robot, context in
            try await self.service.setScheduleEnabled(device: robot, entry: entry, enabled: enabled, expectedContext: context)
        }
    }

    func deleteSchedule(_ entry: ScheduleEntry) async -> Bool {
        guard !isBusy else { return false }
        if let reason = scheduleWriteUnavailableReason { scheduleError = reason; return false }
        if isDemo {
            scheduleSnapshot = ScheduleSnapshot(entries: (scheduleSnapshot?.entries ?? []).filter { $0.id != entry.id }, timezone: "Demo clock")
            scheduleError = ""; return true
        }
        return await mutateSchedule { robot, context in
            try await self.service.deleteSchedule(device: robot, entry: entry, expectedContext: context)
        }
    }

    private func mutateSchedule(_ operation: (RobotDevice, ScheduleContextSnapshot) async throws -> ScheduleContextSnapshot) async -> Bool {
        guard !isBusy, isAuthenticated, !isDemo, let robot = selectedDevice,
              let context = scheduleContext, scheduleWriteUnavailableReason == nil else { return false }
        let scope = scheduleScope
        isBusy = true; isSchedulesLoading = true; scheduleError = ""
        defer { isBusy = false; isSchedulesLoading = false }
        await awaitLiveRequestSlot()
        do {
            let result = try await operation(robot, context)
            guard scheduleScope == scope, isAuthenticated, !isDemo, selectedDevice == robot else { return false }
            acceptSchedules(result)
            scheduleWriteUncertain = false
            return true
        } catch {
            guard scheduleScope == scope else { return false }
            if error is ScheduleWriteError { scheduleWriteUncertain = true }
            scheduleError = error.localizedDescription
            if await service.sessionExpiration() == nil { clearPresentation() }
            return false
        }
    }

    private func acceptSchedules(_ context: ScheduleContextSnapshot) {
        // Read-only context includes the actual current map, so a user can
        // schedule from the dashboard without separately visiting the map tab.
        if let map = context.map {
            applyRoomMap(RoomMap(mapID: map.mapID, rooms: map.floorplan.rooms, mapRevision: map.editVersion))
            floorplan = map.floorplan
        }
        scheduleContext = context; scheduleSnapshot = context.snapshot
    }

    private func demoSchedule(_ draft: ScheduleDraft, id: String) throws -> ScheduleEntry {
        ScheduleEntry(id: id, name: draft.name, enabled: draft.enabled, hour: draft.hour, minute: draft.minute,
            weekdays: draft.weekdays.sorted(), mode: draft.mode, roomIDs: draft.roomIDs, mapID: draft.mapID,
            cron: try NarwalScheduleCodec.weeklyCron(hour: draft.hour, minute: draft.minute, weekdays: draft.weekdays),
            supportedEditReason: nil, originalJSON: Data())
    }
}
