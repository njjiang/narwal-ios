import SwiftUI

@MainActor
struct ScheduleListView: View {
    @EnvironmentObject private var store: FreoStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editor: ScheduleEditorSelection?
    @State private var deletion: ScheduleEntry?

    private var connectionScope: String {
        "\(store.isDemo)-\(store.isAuthenticated)-\(store.selectedDeviceID ?? "none")"
    }

    var body: some View {
        List {
            if !store.isDemo && !store.isAuthenticated {
                Section {
                    ContentUnavailableView("Connect your robot", systemImage: "calendar.badge.clock",
                                           description: Text("Your scheduled cleanings will appear here."))
                    Button("Connection settings") { store.selectedTab = 2 }
                        .scheduleListRow()
                }
            } else {
                if let snapshot = store.scheduleSnapshot {
                    Section {
                        if snapshot.entries.isEmpty && snapshot.unsupportedReason != nil {
                            ContentUnavailableView("Schedules unavailable", systemImage: "calendar.badge.clock",
                                                   description: Text("This schedule format cannot be displayed yet."))
                        } else if snapshot.entries.isEmpty {
                            ContentUnavailableView("No scheduled cleanings", systemImage: "calendar.badge.clock",
                                                   description: Text("Add a time, repeat days, and rooms."))
                        } else {
                            ForEach(snapshot.entries) { entry in
                                scheduleRow(entry)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button("Delete", role: .destructive) { deletion = entry }
                                            .disabled(store.isBusy || store.scheduleWriteUnavailableReason != nil)
                                    }
                            }
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if store.isDemo {
                                Text("Demo only. No robot schedule is created.")
                            } else if let timezone = snapshot.timezone {
                                Text("Robot time · \(timezone)")
                            } else {
                                Text("Robot timezone unavailable.")
                            }
                            if let reason = snapshot.unsupportedReason { Text(reason) }
                        }
                    }
                } else if store.isSchedulesLoading {
                    Section { ProgressView("Loading schedules…") }
                } else {
                    Section {
                        ContentUnavailableView("Schedules not loaded", systemImage: "calendar.badge.clock",
                                               description: Text("Refresh to read your robot’s saved schedules."))
                    }
                }

                Section {
                    Button {
                        editor = ScheduleEditorSelection(entry: nil)
                    } label: {
                        Text("New schedule")
                    }
                    .disabled(store.isBusy || store.scheduleCreateUnavailableReason != nil)
                    .scheduleListRow()
                } footer: {
                    if let reason = store.scheduleCreateUnavailableReason {
                        Text(reason)
                    }
                }
            }

            if !store.scheduleError.isEmpty {
                Section {
                    Text(store.scheduleError).font(.footnote).foregroundStyle(FreoPalette.warning)
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .navigationTitle("Scheduled cleaning")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.loadSchedules() } } label: {
                    if store.isSchedulesLoading { ProgressView() }
                    else { Label("Refresh schedules", systemImage: "arrow.clockwise") }
                }
                .disabled(store.isBusy || (!store.isAuthenticated && !store.isDemo))
            }
        }
        .refreshable {
            guard !store.isBusy, store.isDemo || store.isAuthenticated else { return }
            await store.loadSchedules()
        }
        .task(id: connectionScope) {
            editor = nil
            deletion = nil
            if store.isDemo || store.isAuthenticated { await store.loadSchedules() }
        }
        .sheet(item: $editor) { selection in
            ScheduleEditorView(entry: selection.entry)
        }
        .confirmationDialog("Delete schedule?", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible) {
            if let deletion {
                Button("Delete schedule", role: .destructive) {
                    let entry = deletion
                    self.deletion = nil
                    Task { _ = await store.deleteSchedule(entry) }
                }
            }
        } message: {
            Text(store.isDemo ? "This removes the demo schedule." : "This removes the saved schedule from Narwal.")
        }
    }

    private func scheduleRow(_ entry: ScheduleEntry) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        return layout {
            Button { editor = ScheduleEditorSelection(entry: entry) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SchedulePresentation.time(hour: entry.hour, minute: entry.minute))
                        .font(.title3.weight(.medium)).monospacedDigit()
                    Text(entry.name.isEmpty ? "Scheduled cleaning" : entry.name)
                        .font(.body)
                    Text(SchedulePresentation.repeatSummary(entry.weekdays))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(SchedulePresentation.task(entry, floorplan: store.floorplan))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !entry.canEdit {
                        Text("View only").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(FreoPalette.primaryText)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let enabled = entry.enabled {
                enabledToggle(entry, enabled: enabled)
            } else {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .scheduleListRow()
    }

    @ViewBuilder
    private func enabledToggle(_ entry: ScheduleEntry, enabled: Bool) -> some View {
        let toggle = Toggle("Enabled", isOn: Binding(
            get: { enabled },
            set: { value in Task { _ = await store.setScheduleEnabled(entry, enabled: value) } }
        ))
        .accessibilityLabel("Enable \(entry.name.isEmpty ? "schedule" : entry.name)")
        .frame(minHeight: 44)
        .disabled(store.isBusy || !entry.canEdit || store.scheduleWriteUnavailableReason != nil)
        if dynamicTypeSize.isAccessibilitySize { toggle }
        else { toggle.labelsHidden() }
    }
}

private struct ScheduleEditorSelection: Identifiable {
    let id = UUID()
    let entry: ScheduleEntry?
}

@MainActor
private struct ScheduleEditorView: View {
    @EnvironmentObject private var store: FreoStore
    @Environment(\.dismiss) private var dismiss
    let entry: ScheduleEntry?
    @State private var draft: ScheduleDraft
    @State private var saving = false

    init(entry: ScheduleEntry?) {
        self.entry = entry
        _draft = State(initialValue: entry.map(ScheduleDraft.init(entry:)) ?? ScheduleDraft())
    }

    private var isReadOnly: Bool { entry?.canEdit == false }
    private var saveBlocker: String? {
        if let reason = entry?.supportedEditReason { return reason }
        if let reason = entry == nil ? store.scheduleCreateUnavailableReason : store.scheduleWriteUnavailableReason { return reason }
        if draft.weekdays.isEmpty { return "Choose at least one repeat day." }
        if entry == nil && draft.roomIDs.isEmpty { return "Choose at least one room." }
        if entry == nil && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give this schedule a name."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if isReadOnly, let entry {
                    Section {
                        LabeledContent("Name", value: entry.name.isEmpty ? "Scheduled cleaning" : entry.name).scheduleListRow()
                        LabeledContent("Time", value: SchedulePresentation.time(hour: entry.hour, minute: entry.minute)).scheduleListRow()
                        LabeledContent("Repeat", value: SchedulePresentation.repeatSummary(entry.weekdays)).scheduleListRow()
                        if let enabled = entry.enabled { LabeledContent("Enabled", value: enabled ? "Yes" : "No").scheduleListRow() }
                    }
                } else {
                    Section {
                        if entry == nil {
                            TextField("Name", text: $draft.name)
                                .textInputAutocapitalization(.sentences)
                                .submitLabel(.done)
                                .scheduleListRow()
                        } else if let entry {
                            LabeledContent("Name", value: entry.name).scheduleListRow()
                        }
                        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.compact)
                            .environment(\.timeZone, SchedulePresentation.clockZone)
                            .scheduleListRow()
                        NavigationLink {
                            ScheduleRepeatPicker(weekdays: $draft.weekdays)
                        } label: {
                            LabeledContent("Repeat", value: draft.weekdays.isEmpty ? "Choose days" : SchedulePresentation.repeatSummary(draft.weekdays))
                        }
                        .scheduleListRow()
                        Toggle("Enabled", isOn: $draft.enabled).scheduleListRow()
                    } footer: {
                        if let timezone = store.scheduleSnapshot?.timezone {
                            Text("Robot time · \(timezone)")
                        }
                    }
                    .disabled(store.isBusy || saving)
                }

                if let entry {
                    Section {
                        Text(SchedulePresentation.task(entry, floorplan: store.floorplan))
                            .scheduleListRow()
                    } header: {
                        Text("Cleaning task")
                    } footer: {
                        if !isReadOnly {
                            Text("Time, repeat days, and enabled state can change. Cleaning settings are preserved.")
                        }
                    }
                } else {
                    Section {
                        Picker("Mode", selection: $draft.mode) {
                            ForEach(CleaningMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .scheduleListRow()
                        ForEach(store.rooms) { room in
                            Toggle(room.name, isOn: Binding(
                                get: { draft.roomIDs.contains(room.id) },
                                set: { selected in
                                    if selected { draft.roomIDs = Array(Set(draft.roomIDs + [room.id])).sorted() }
                                    else { draft.roomIDs.removeAll { $0 == room.id } }
                                }
                            ))
                            .scheduleListRow()
                        }
                        HStack {
                            Button("Deselect all") { draft.roomIDs = [] }
                            Spacer()
                            Button("Select all") { draft.roomIDs = store.rooms.map(\.id).sorted() }
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .scheduleListRow()
                    } header: {
                        Text("Cleaning task")
                    } footer: {
                        Text("Standard cleaning options. Main-map rooms only; zones and secondary maps cannot be scheduled.")
                    }
                    .disabled(store.isBusy || saving)
                }

                if let blocker = saveBlocker {
                    Section { Text(blocker).font(.footnote).foregroundStyle(.secondary) }
                }
                if !store.scheduleError.isEmpty && store.scheduleError != saveBlocker {
                    Section { Text(store.scheduleError).font(.footnote).foregroundStyle(FreoPalette.warning) }
                }
            }
            .environment(\.defaultMinListRowHeight, 44)
            .navigationTitle(entry == nil ? "New schedule" : "Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isReadOnly ? "Done" : "Cancel") { dismiss() }.disabled(saving)
                }
                if !isReadOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            saving = true
                            Task {
                                let saved = await store.saveSchedule(draft: draft, existing: entry)
                                saving = false
                                if saved { dismiss() }
                            }
                        } label: {
                            if saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                        }
                        .disabled(saving || store.isBusy || saveBlocker != nil)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                if entry == nil {
                    draft.roomIDs = store.selectedRoomIDs.sorted()
                    draft.mode = store.mode
                    draft.mapID = store.floorplan?.mapID
                }
            }
        }
    }

    // Dates are only a UI carrier. A fixed timezone keeps the chosen hour and
    // minute literal; the schedule service applies the verified robot timezone.
    private var timeBinding: Binding<Date> {
        Binding(get: { SchedulePresentation.date(hour: draft.hour, minute: draft.minute) }, set: { value in
            let components = SchedulePresentation.clockCalendar.dateComponents([.hour, .minute], from: value)
            draft.hour = components.hour ?? draft.hour
            draft.minute = components.minute ?? draft.minute
        })
    }
}

private struct ScheduleRepeatPicker: View {
    @Binding var weekdays: [Int]
    var body: some View {
        List(1...7, id: \.self) { day in
            Button {
                if weekdays.contains(day) { weekdays.removeAll { $0 == day } }
                else { weekdays = Array(Set(weekdays + [day])).sorted() }
            } label: {
                HStack {
                    Text(SchedulePresentation.day(day, abbreviated: false)).foregroundStyle(.primary)
                    Spacer()
                    if weekdays.contains(day) { Image(systemName: "checkmark").fontWeight(.semibold) }
                }
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
            .scheduleListRow()
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .navigationTitle("Repeat")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension View {
    func scheduleListRow() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

private enum SchedulePresentation {
    static let clockZone = TimeZone(secondsFromGMT: 0)!
    static var clockCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = clockZone
        return calendar
    }
    static func date(hour: Int, minute: Int) -> Date {
        clockCalendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))!
    }
    static func time(hour: Int?, minute: Int?) -> String {
        guard let hour, let minute, (0...23).contains(hour), (0...59).contains(minute) else { return "Time unavailable" }
        let formatter = DateFormatter()
        formatter.timeZone = clockZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date(hour: hour, minute: minute))
    }
    static func day(_ isoDay: Int, abbreviated: Bool) -> String {
        let symbols = abbreviated ? Calendar.current.shortWeekdaySymbols : Calendar.current.weekdaySymbols
        return symbols[isoDay % 7]
    }
    static func repeatSummary(_ days: [Int]?) -> String {
        guard let days, !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else { return "Repeat days unavailable" }
        let selected = Set(days)
        if selected == Set(1...7) { return "Every day" }
        if selected == Set(1...5) { return "Weekdays" }
        if selected == Set([6, 7]) { return "Weekends" }
        return selected.sorted().map { day($0, abbreviated: true) }.joined(separator: ", ")
    }
    static func task(_ entry: ScheduleEntry, floorplan: Floorplan?) -> String {
        let rooms = entry.mapID != nil && entry.mapID == floorplan?.mapID ? floorplan?.rooms ?? [] : []
        var parts = [entry.mode?.title ?? "Saved cleaning settings"]
        if let ids = entry.roomIDs, !ids.isEmpty {
            parts.append(ids.map { id in rooms.first { $0.id == id }?.name ?? "Room \(id)" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}
