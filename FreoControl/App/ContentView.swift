import SwiftUI
import UIKit
import AppIntents


@MainActor
struct ContentView: View {
    @EnvironmentObject private var store: FreoStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var lastMainTab = 1
    @State private var presentedSheet: Sheet?
    @State private var connectionAfterDismiss = false
    @State private var mapPageVisible = false
    @State private var mapCommandFeedback = ""
    @State private var roomActionSelection: Set<Int> = []

    private enum Sheet: String, Identifiable {
        case connection, roomEditor, roomNames, cleaningOptions, robotDetails, mapUpdates
        var id: String { rawValue }
    }

    // Siri can still request the Connection destination with selectedTab = 2.
    // Keep the underlying tab on Robot or Floorplan while the sheet is open.
    private var mainTabSelection: Binding<Int> {
        Binding(
            get: { store.selectedTab == 2 ? lastMainTab : store.selectedTab },
            set: { store.selectedTab = $0 }
        )
    }

    var body: some View {
        TabView(selection: mainTabSelection) {
            NavigationStack {
                mapPage
                    .navigationTitle("Floorplan")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        connectionToolbar
                        ToolbarItemGroup(placement: .topBarLeading) {
                            if !store.isDemo {
                                Button { Task { await store.loadFloorplan() } } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .accessibilityLabel("Refresh floorplan")
                                .disabled(store.isBusy || !store.isAuthenticated)
                            }
                            if store.floorplan != nil { roomSelectionToggle }
                            if store.isDemo { StatusPill(text: "Demo") }
                        }
                    }
            }
            .tabItem { Label("Floorplan", systemImage: "square.split.2x2") }
            .tag(1)

            NavigationStack {
                dashboard
                    .navigationTitle("Narwal")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { connectionToolbar }
            }
            .tabItem { Label("Robot", systemImage: "circle.circle") }
            .tag(0)
        }
        .onChange(of: store.selectedTab, initial: true) { _, destination in
            if destination == 2 {
                if presentedSheet != nil && presentedSheet != .connection {
                    connectionAfterDismiss = true
                    presentedSheet = nil
                } else {
                    presentedSheet = .connection
                }
            } else {
                lastMainTab = destination
                connectionAfterDismiss = false
                // A successful Siri action switches to Robot. Reveal its
                // result even if the user left the room editor open.
                if presentedSheet == .connection || (destination == 0 && presentedSheet != nil) {
                    presentedSheet = nil
                }
            }
            syncMapVisibility()
        }
        .onChange(of: presentedSheet) { _, _ in syncMapVisibility() }
        .sheet(item: $presentedSheet, onDismiss: sheetDismissed) { sheet in
            switch sheet {
            case .connection:
                NavigationStack {
                    ConnectionView()
                        .navigationTitle("Connection")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { presentedSheet = nil } label: {
                                    Label("Close connection settings", systemImage: "xmark")
                                }
                                .labelStyle(.iconOnly)
                                .accessibilityIdentifier("closeConnectionSettings")
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            case .roomEditor:
                RoomEditorView(initialRoomIDs: roomActionSelection)
            case .roomNames:
                RoomNamesView(initialRoomIDs: roomActionSelection)
            case .cleaningOptions:
                CleaningOptionsView()
            case .robotDetails:
                informationSheet("Robot details") { robotDetails }
            case .mapUpdates:
                informationSheet("Map updates") {
                    Section { mapConnectionStatus }
                }
            }
        }
    }

    private var connectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { store.selectedTab = 2 } label: {
                Label("Connection settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("connectionSettings")
        }
    }

    private func sheetDismissed() {
        if connectionAfterDismiss {
            connectionAfterDismiss = false
            presentedSheet = .connection
        } else if store.selectedTab == 2 {
            store.selectedTab = lastMainTab
        }
    }

    private func syncMapVisibility() {
        store.setMapVisible(mapPageVisible && store.selectedTab == 1 &&
                            (presentedSheet == nil || presentedSheet == .mapUpdates))
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                robotSurface
                if !store.message.isEmpty && store.message != store.currentTaskError { StoreNotice() }
                robotNavigation
                RobotCleaningHistorySection()
            }
            .padding(16)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.bottom, 20, for: .scrollContent)
        .background(FreoPalette.background)
    }

    private var robotNavigation: some View {
        NavigationLink {
            ScheduleListView()
        } label: {
            Label("Schedule", systemImage: "calendar")
        }
        .buttonStyle(FreoSecondaryButtonStyle())
    }

    private var robotSurface: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image("FreoLogo")
                        .resizable().scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.selectedDevice?.name ?? "Narwal Freo X Ultra")
                            .font(.headline).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Label(batteryText, systemImage: "battery.100percent")
                                .monospacedDigit()
                                .accessibilityLabel("Battery \(batteryText)")
                            if store.isDemo { Text("Demo") }
                        }
                        .font(.footnote).foregroundStyle(FreoPalette.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if store.isBusy || store.isCurrentTaskLoading {
                        ProgressView().frame(width: 44, height: 44)
                            .accessibilityLabel(store.isCurrentTaskLoading ? "Reading current task" : "Request in progress")
                    } else if !store.isDemo {
                        Button { Task { await store.refreshStatus() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(FreoIconButtonStyle())
                        .accessibilityLabel("Refresh robot status")
                        .disabled(!store.isAuthenticated)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text(store.robotActivityTitle).font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if store.isDemo || store.isAuthenticated {
                            Button { presentedSheet = .robotDetails } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(FreoIconButtonStyle())
                            .accessibilityLabel("Robot details")
                        }
                    }
                    currentTaskSummary
                    if !store.isDemo, let status = store.status,
                       context.date.timeIntervalSince(status.updatedAt) > 90 {
                        Text("Status needs refresh")
                            .font(.footnote).foregroundStyle(FreoPalette.warning)
                    }
                    if !store.currentTaskError.isEmpty {
                        Text(store.currentTaskError)
                            .font(.footnote).foregroundStyle(FreoPalette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if store.isDemo || store.isAuthenticated {
                    currentCleanControls()
                } else {
                    Button("Connect robot") { store.selectedTab = 2 }
                        .buttonStyle(FreoPrimaryButtonStyle())
                }
            }
            .foregroundStyle(FreoPalette.primaryText)
            .freoCard()
        }
        .task(id: store.isAuthenticated ? store.selectedDeviceID : nil) {
            if store.isAuthenticated { await store.refreshCurrentTask() }
        }
    }

    @ViewBuilder
    private var currentTaskSummary: some View {
        if let task = store.currentTask, store.currentTaskIsFresh {
            Text(task.rooms.isEmpty ? "Room names unavailable" : task.rooms.map(\.name).joined(separator: ", "))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !task.modeNames.isEmpty {
                Text(task.modeNames.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
            }
            if task.hasUnknownRoomTargets || !task.unresolvedRoomIDs.isEmpty {
                Text("Some assigned room names are unavailable.")
                    .font(.footnote).foregroundStyle(FreoPalette.secondaryText)
            }
            if store.status?.isPaused != true {
                if [2, 3].contains(store.status?.stationContactCode ?? 0) {
                    Label("At dock", systemImage: "house")
                        .font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
                } else if let room = store.currentPositionRoom {
                    Label(room.name, systemImage: "location.fill")
                        .font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
                        .accessibilityLabel("Robot position: \(room.name)")
                }
            }
        } else if store.isAuthenticated && store.robotActivityTitle != "Standby" && store.robotActivityTitle != "Status unavailable" {
            if store.isCurrentTaskLoading {
                Text("Reading current task…")
                    .font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
            } else if store.currentTaskError.isEmpty {
                Text(store.currentTask == nil ? "Current task unavailable" : "Task needs refresh")
                    .font(.footnote).foregroundStyle(FreoPalette.secondaryText)
            }
        }
    }

    private var batteryText: String {
        guard let value = store.status?.battery, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func informationSheet<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            Form { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { presentedSheet = nil }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var robotDetails: some View {
        Group {
            Section("Robot") {
                LabeledContent("Status", value: store.robotActivityTitle)
                LabeledContent("Battery", value: batteryText)
                if let contact = store.status?.stationContactLabel {
                    LabeledContent("Dock", value: contact)
                }
                if !store.isDemo, let status = store.status {
                    LabeledContent("Status received", value: status.updatedAt.formatted(date: .omitted, time: .shortened))
                }
                if let updated = store.currentTaskUpdatedAt {
                    LabeledContent("Task received", value: updated.formatted(date: .omitted, time: .shortened))
                }
                Button("Refresh current task") { Task { await store.refreshCurrentTask() } }
                    .disabled(store.isBusy || store.isCurrentTaskLoading || store.isDemo || !store.isAuthenticated)
            }
            Section("Last returned setup") {
                Button("Read cleaning setup") { Task { await store.checkPlan() } }
                    .disabled(store.isBusy || (!store.isDemo && !store.isAuthenticated))
                if !store.isDemo, let status = store.status {
                    LabeledContent("Robot-reported suction", value: status.reportedSuctionLabel ?? "Unavailable")
                }
                if !store.isDemo, let supported = store.supportsSweepIntensity {
                    LabeledContent("Separate sweep intensity", value: supported ? "Supported" : "Not supported")
                }
                if store.isDemo {
                    Text("Demo settings.").foregroundStyle(FreoPalette.secondaryText)
                } else if let plan = store.lastPlan {
                    if plan.samples.isEmpty {
                        Text("No current task returned.").foregroundStyle(FreoPalette.secondaryText)
                    }
                    ForEach(Array(plan.samples.enumerated()), id: \.offset) { _, sample in
                        if !sample.reportedSettings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sample.roomID.flatMap { id in store.rooms.first { $0.id == id }?.name }
                                     ?? sample.roomID.map { "Room \($0)" } ?? "Cleaning task")
                                    .font(.subheadline.weight(.medium))
                                Text(sample.reportedSettings.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(FreoPalette.secondaryText)
                            }
                        }
                    }
                }
            }
            if !store.currentTaskError.isEmpty {
                Section { Text(store.currentTaskError).foregroundStyle(FreoPalette.warning) }
            }
        }
    }

    private func currentCleanControls(reportsOnMap: Bool = false) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            commandButton("Pause", symbol: "pause.fill", action: .pause, reportsOnMap: reportsOnMap)
            commandButton("Resume", symbol: "play.circle", action: .resume, reportsOnMap: reportsOnMap)
            commandButton("Dock", symbol: "house", action: .dock, reportsOnMap: reportsOnMap)
        }
    }

    @ViewBuilder
    private func commandButton(_ title: String, symbol: String, action: RobotAction, primary: Bool = false, reportsOnMap: Bool = false) -> some View {
        let compact = reportsOnMap && !dynamicTypeSize.isAccessibilitySize
        let button = Button {
            if reportsOnMap { mapCommandFeedback = "" }
            Task {
                await store.send(action: action)
                if reportsOnMap && mapPageVisible && store.selectedTab == 1 {
                    mapCommandFeedback = store.message
                }
            }
        } label: {
            if primary || compact || dynamicTypeSize.isAccessibilitySize {
                Label(title, systemImage: symbol)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: symbol)
                    Text(title).font(.subheadline.weight(.semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel(title)
        .disabled(!canSend(action))
        if primary {
            button.buttonStyle(FreoPrimaryButtonStyle(compact: compact))
        } else {
            button.buttonStyle(FreoSecondaryButtonStyle(compact: compact))
        }
    }

    private func canSend(_ action: RobotAction) -> Bool {
        guard !store.isBusy else { return false }
        if action == .start { return store.canStart }
        if store.isDemo {
            let code = store.status?.workingCode
            switch action {
            case .pause: return code == 4 || code == 5
            case .resume: return code == 2
            case .dock: return code == 2 || code == 4 || code == 5
            case .start: return store.canStart
            }
        }
        return store.isAuthenticated && store.selectedDevice?.canControl == true
    }

    private var mapPage: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let floorplan = store.floorplan {
                        TimelineView(.periodic(from: .now, by: 5)) { _ in
                            FloorplanView(floorplan: floorplan,
                                          selectedRoomIDs: store.selectedRoomIDs,
                                          isDemo: store.isDemo, isBusy: store.isBusy, toggleRoom: store.toggleRoom,
                                          route: store.trajectory.map { FloorplanRouteOverlay(trajectory: $0, showsRobotPosition: store.isDemo || store.currentPositionRoom != nil) },
                                          allowsRoomSelection: true,
                                          taskRoomIDs: store.currentTaskRoomIDs,
                                          robotRoomID: store.currentTaskIsFresh && store.status?.isPaused != true &&
                                            ![2, 3].contains(store.status?.stationContactCode ?? 0)
                                            ? store.currentPositionRoom.flatMap { store.currentTaskRoomIDs.contains($0.id) ? $0.id : nil }
                                            : nil,
                                          maximumCanvasHeight: max(220, viewport.size.height - 8),
                                          onEditRooms: (store.isDemo || store.isAuthenticated) ? {
                                              roomActionSelection = store.selectedRoomIDs
                                              presentedSheet = .roomEditor
                                          } : nil,
                                          onRenameRooms: (store.isDemo || store.isAuthenticated) ? {
                                              roomActionSelection = store.selectedRoomIDs
                                              presentedSheet = .roomNames
                                          } : nil,
                                          onMapUpdates: store.isDemo ? nil : { presentedSheet = .mapUpdates })
                                .id("\(store.isDemo)-\(store.selectedDeviceID ?? "none")-\(floorplan.mapID)")
                        }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "square.split.2x2").font(.largeTitle.weight(.light))
                                .foregroundStyle(FreoPalette.secondaryText)
                            Text("No floorplan loaded").font(.headline)
                            if !store.isDemo && !store.isAuthenticated {
                                Button("Connect robot") { store.selectedTab = 2 }
                                    .buttonStyle(FreoPrimaryButtonStyle())
                            } else if !store.isDemo {
                                Button("Load floorplan") { Task { await store.loadFloorplan() } }
                                    .buttonStyle(FreoPrimaryButtonStyle())
                                    .disabled(store.isBusy)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .padding(.horizontal, 24)
                    }
                    if store.floorplan == nil && !store.message.isEmpty { StoreNotice() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
            }
        }
        .background(FreoPalette.background)
        .safeAreaInset(edge: .bottom, spacing: 6) {
            mapControlTray
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .onAppear {
            mapPageVisible = true
            syncMapVisibility()
        }
        .onDisappear {
            mapPageVisible = false
            mapCommandFeedback = ""
            syncMapVisibility()
        }
    }

    private var roomSelectionToggle: some View {
        let roomIDs = Set(store.floorplan?.rooms.map(\.id) ?? [])
        let allSelected = !roomIDs.isEmpty && roomIDs.isSubset(of: store.selectedRoomIDs)
        return Button {
                if allSelected { store.deselectAllRooms() }
                else { store.selectAllRooms() }
            } label: {
                Image(systemName: allSelected ? "checkmark.circle.fill" : "circle.dashed")
            }
            .accessibilityLabel(allSelected ? "Deselect all rooms" : "Select all rooms")
            .accessibilityAddTraits(allSelected ? .isSelected : [])
            .disabled(store.isBusy || roomIDs.isEmpty)
    }

    private var mapControlTray: some View {
        VStack(alignment: .leading, spacing: 6) {
            CleaningModeSwipePicker(mode: $store.mode, isBusy: store.isBusy)
            HStack(spacing: 8) {
                commandButton(mapStartTitle, symbol: "play.fill", action: .start, primary: true, reportsOnMap: true)
                Button { presentedSheet = .cleaningOptions } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(FreoIconButtonStyle())
                .accessibilityLabel("Cleaning options")
                .disabled(store.isBusy)
            }
            currentCleanControls(reportsOnMap: true)
            if !mapCommandFeedback.isEmpty {
                Text(mapCommandFeedback)
                    .font(.footnote).foregroundStyle(FreoPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: 800)
        .background(FreoPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    private var mapStartTitle: String {
        let count = store.selectedRoomIDs.count
        return count == 0 ? "Start" : "Start · \(count) \(count == 1 ? "room" : "rooms")"
    }

    private var mapConnectionStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            if store.isFloorplanCached {
                Text("Saved map · waiting for robot updates").font(.caption)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    mapConnectionLabel
                    Spacer(minLength: 12)
                    mapReceivedLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    mapConnectionLabel
                    mapReceivedLabel
                }
            }
            if !store.isDemo && store.liveMapState == .polling && !store.liveMapMessage.isEmpty {
                DisclosureGroup("Connection details") {
                    Text(store.liveMapMessage).font(.footnote).padding(.top, 4)
                }
                .font(.footnote)
            }
            if !store.trajectoryError.isEmpty {
                Text(store.trajectoryError).font(.caption)
            } else if let reason = store.trajectory?.unavailableReason, !reason.isEmpty {
                Text(reason).font(.caption)
            }
        }
        .foregroundStyle(FreoPalette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mapConnectionLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(!store.isDemo && store.liveMapState == .live ? FreoPalette.accent : FreoPalette.secondaryText)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("Position updates: \(mapConnectionTitle)").font(.caption.weight(.semibold))
        }
        .accessibilityLabel("Path updates: \(mapConnectionTitle)")
    }

    @ViewBuilder
    private var mapReceivedLabel: some View {
        if let trajectory = store.trajectory {
            Text("Received \(trajectory.capturedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).monospacedDigit()
        }
    }

    private var mapConnectionTitle: String {
        if store.isDemo { return "Simulated" }
        switch store.liveMapState {
        case .inactive: return "Updates paused"
        case .connecting: return "Connecting"
        case .waiting: return "Waiting"
        case .live: return "Live"
        case .polling: return "Periodic updates"
        }
    }


}

@MainActor
struct ConnectionView: View {
    @EnvironmentObject private var store: FreoStore
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?
    private enum Field { case email, password }

    var body: some View {
        Form {
            if !store.isDemo {
                if store.isAuthenticated { accountSection } else { signInSection }
                }

            if !store.message.isEmpty {
                Section {
                    StoreNotice()
                        .listRowInsets(EdgeInsets())
                }
            }

            if store.savedSessionRemovalPending && !store.isDemo {
                Section {
                    Button("Remove saved sign-in") { Task { await store.removeSavedSignIn() } }
                        .disabled(store.isBusy)
                }
            }

            Section {
                DisclosureGroup("Siri & Shortcuts") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Say “Run Narwal vacuum” and choose a room, “Pause Narwal”, or “Stop Narwal” to return the robot to its dock.")
                        ShortcutsLink()
                        Text("For a shorter phrase, save a personal shortcut named “Clean rooms” with its cleaning mode and rooms set to Ask Each Time.")
                    }
                    .font(.footnote).foregroundStyle(FreoPalette.secondaryText)
                    .padding(.vertical, 8)
                }
                DisclosureGroup("Connection & privacy") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connects to Narwal’s US service using TLS. Narwal may process or forward data elsewhere.")
                        Text("Firewall rules scoped only to the robot’s local address do not cover requests from this iPhone.")
                        Text("Your sign-in is saved securely on this iPhone. Sign out removes it.")
                        Text("Map edits save a private snapshot on this device, excluded from backups. Snapshot restore is not supported.")
                    }
                    .font(.footnote).foregroundStyle(FreoPalette.secondaryText)
                    .padding(.vertical, 8)
                }
            }

            Section {
                Toggle("Demo mode", isOn: Binding(get: { store.isDemo }, set: { store.setDemo($0) }))
                    .disabled(store.isBusy)
            } footer: {
                if store.isDemo { Text("Simulated data. No robot requests.") }
            }
        }
        .environment(\.defaultMinListRowHeight, 44)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .background(FreoPalette.background)
    }

    private var signInSection: some View {
        Section {
            TextField("Narwal email", text: $email)
                .keyboardType(.emailAddress).textContentType(.username)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.next).focused($focusedField, equals: .email)
                .onSubmit { focusedField = .password }
                .accessibilityLabel("Narwal email")
                .frame(minHeight: 28)
            SecureField("Narwal password", text: $password)
                .textContentType(.password).submitLabel(.go)
                .focused($focusedField, equals: .password)
                .onSubmit(signIn)
                .accessibilityLabel("Narwal password")
                .frame(minHeight: 28)
            Button(action: signIn) {
                HStack(spacing: 8) {
                    if store.isBusy { ProgressView().tint(FreoPalette.onAccent) }
                    Text(store.isBusy ? "Connecting…" : "Sign in")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(FreoPrimaryButtonStyle())
            .disabled(store.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            if store.canRetrySavedSignIn {
                Button("Retry saved sign-in") { Task { await store.restoreSavedSession() } }
            }
        } header: {
            Text("Narwal account")
        } footer: {
            Text("Use your separate Narwal password. You stay signed in until you sign out or Narwal requires sign-in again.")
        }
        .disabled(store.isBusy)
    }

    private var accountSection: some View {
        Section {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(FreoPalette.success)
            Picker("Robot", selection: Binding(get: { store.selectedDeviceID ?? "" }, set: { store.selectDevice($0) })) {
                if store.devices.isEmpty { Text("No robot found").tag("") }
                ForEach(store.devices) { device in Text(device.name).tag(device.id) }
            }
            .pickerStyle(.menu).disabled(store.isBusy)
            if let device = store.selectedDevice {
                if let firmware = device.firmware {
                    LabeledContent("Firmware", value: firmware)
                }
                if let suffix = device.serialSuffix {
                    LabeledContent("Serial ending", value: suffix)
                }
            }
            Button("Sign out", role: .destructive) {
                store.disconnect()
                email = ""
                password = ""
            }
            .disabled(store.isBusy)
        } header: {
            Text("Narwal account")
        } footer: {
            if let expires = store.sessionExpiry, expires != .distantFuture {
                Text("Session expires \(expires.formatted(date: .omitted, time: .shortened)).")
            }
        }
    }

    private func signIn() {
        guard !store.isBusy, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        let suppliedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedPassword = password
        password = ""
        focusedField = nil
        Task { await store.signIn(email: suppliedEmail, password: suppliedPassword) }
    }
}

@MainActor
struct StoreNotice: View {
    @EnvironmentObject private var store: FreoStore
    private var needsAttention: Bool {
        let text = store.message.lowercased()
        return ["unknown", "timed out", "failed", "could not", "error", "rejected", "expired"].contains(where: text.contains)
    }
    var body: some View {
        Label(store.message, systemImage: needsAttention ? "exclamationmark.triangle" : "info.circle")
            .font(.footnote).lineSpacing(2)
            .foregroundStyle(needsAttention ? FreoPalette.warning : FreoPalette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(needsAttention ? FreoPalette.warningBackground : FreoPalette.selection,
                        in: RoundedRectangle(cornerRadius: 13))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(store.message)
    }
}

struct StatusPill: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote.weight(.medium))
        .foregroundStyle(FreoPalette.secondaryText)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(FreoPalette.fill, in: Capsule())
    }
}

extension View {
    func freoCard() -> some View {
        padding(16)
            .background(FreoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    func freoField() -> some View {
        padding(13)
            .background(FreoPalette.background, in: RoundedRectangle(cornerRadius: 11))
    }
}
