import SwiftUI

@MainActor
struct CleaningHistoryView: View {
    @EnvironmentObject private var store: FreoStore
    @State private var runToDelete: CleaningRun?
    @State private var showingHistoryInfo = false

    var body: some View {
        Group {
            if store.isHistoryLoading && store.cleaningHistory.isEmpty {
                ProgressView("Loading paths…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.cleaningHistory.isEmpty && store.historyError.isEmpty && !store.isAuthenticated {
                ContentUnavailableView {
                    Label("No saved paths", systemImage: "clock")
                } description: {
                    Text("Connect your robot to load its history.")
                }
            } else {
                historyList
            }
        }
        .background(FreoPalette.background)
        .navigationTitle("Cleaning history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.isAuthenticated && !store.isDemo {
                    HistorySyncButton(isLoading: store.isCloudHistoryLoading,
                                      isCancelling: store.isCloudHistoryCancelling,
                                      isBusy: store.isBusy) {
                        Task { await store.loadCloudHistory() }
                    } cancel: {
                        store.cancelCloudHistorySync()
                    }
                }
                Button { showingHistoryInfo = true } label: {
                    Label("About cleaning history", systemImage: "info.circle")
                }
                .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $showingHistoryInfo) {
            NavigationStack {
                List {
                    Section("Sources") {
                        Label("Narwal: a record from your robot’s history.", systemImage: "cloud")
                        Label("Partial recording: a route saved while this app was open. Mode and rooms come from the robot’s task during capture.", systemImage: "record.circle")
                    }
                    Section("Saved on this device") {
                        Text("Sync downloads available paths for offline viewing.")
                        Text("Up to 30 days, 20 recordings, or 48 MB are kept.")
                    }
                    Section("Reading a path") {
                        Text("Missing observations stay blank. A path does not measure cleaning coverage.")
                    }
                }
                .font(.subheadline)
                .navigationTitle("About history")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingHistoryInfo = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task { await store.loadCleaningHistory() }
        .confirmationDialog("Delete this saved path?", isPresented: Binding(
            get: { runToDelete != nil }, set: { if !$0 { runToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete path", role: .destructive) {
                guard let run = runToDelete else { return }
                runToDelete = nil
                Task { await store.deleteCleaningRun(id: run.id) }
            }
        } message: {
            Text("This removes the saved map and path from this device.")
        }
    }

    private var historyList: some View {
        List {
            if store.isAuthenticated && !store.isDemo &&
                (!store.cloudCleaningRecords.isEmpty || !store.cloudHistoryError.isEmpty ||
                 (!store.hasMoreCloudHistory && !store.isCloudHistoryLoading)) {
                cloudHistorySection
            }
            if !store.historyError.isEmpty {
                Section {
                    Text(store.historyError)
                        .font(.subheadline)
                        .foregroundStyle(FreoPalette.warning)
                    Button("Try again") { Task { await store.loadCleaningHistory() } }
                        .buttonStyle(FreoSecondaryButtonStyle())
                        .disabled(store.isHistoryLoading)
                        .historyRow()
                }
            }
            Section {
                if store.cleaningHistory.isEmpty {
                    Text("No paths saved on this device yet.")
                        .foregroundStyle(FreoPalette.secondaryText)
                }
                ForEach(store.cleaningHistory.sorted { $0.startedAt > $1.startedAt }) { run in
                    NavigationLink {
                        CleaningRunDetailView(run: run)
                    } label: {
                        HistorySummaryRow(mode: run.modeName, rooms: run.roomNames,
                                          date: run.startedAt, isCloudRecord: run.isCloudRecord, run: run)
                    }
                    .historyRow()
                    .swipeActions(allowsFullSwipe: false) {
                        Button(role: .destructive) { runToDelete = run } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Saved")
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .refreshable { await store.loadCleaningHistory() }
    }

    private var cloudHistorySection: some View {
        Section {
            if !store.cloudHistoryError.isEmpty {
                Text(store.cloudHistoryError)
                    .font(.subheadline).foregroundStyle(FreoPalette.warning)
            }
            if store.cloudCleaningRecords.isEmpty && !store.hasMoreCloudHistory &&
                !store.isCloudHistoryLoading && store.cloudHistoryError.isEmpty {
                Text("No cleaning records were returned.")
                    .foregroundStyle(FreoPalette.secondaryText)
            }

            ForEach(store.cloudCleaningRecords) { record in
                NavigationLink {
                    CloudCleaningDetailView(record: record)
                } label: {
                    HistorySummaryRow(mode: record.modeName, rooms: record.roomNames,
                                      date: record.startedAt, isCloudRecord: true,
                                      durationSeconds: record.durationSeconds, run: store.cleaningHistory.first {
                                          $0.cloudRecordID == record.id && $0.trajectory.deviceID == record.deviceID &&
                                              $0.trajectory.productKey == record.productKey
                                      })
                }
                .historyRow()
                .disabled(store.isBusy && !store.cleaningHistory.contains {
                    $0.cloudRecordID == record.id && $0.trajectory.deviceID == record.deviceID &&
                        $0.trajectory.productKey == record.productKey
                })
            }
            if !store.cloudCleaningRecords.isEmpty && store.hasMoreCloudHistory {
                Button { Task { await store.loadCloudHistory(loadMore: true) } } label: {
                    Label("Older records", systemImage: "arrow.down")
                }
                    .buttonStyle(FreoSecondaryButtonStyle())
                    .disabled(store.isBusy || store.isCloudHistoryLoading)
                    .historyRow()
            }
        } header: {
            Text("Narwal history")
        }
    }
}

@MainActor
struct CloudCleaningDetailView: View {
    @EnvironmentObject private var store: FreoStore
    let record: CloudCleaningRecord
    @State private var run: CleaningRun?
    @State private var error = ""
    @State private var isLoading = true
    @State private var requested = false
    @State private var storageNotice: String?

    var body: some View {
        Group {
            if let run {
                CleaningRunDetailView(run: run, storageNotice: storageNotice)
            } else if isLoading {
                ProgressView("Loading saved path…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Path unavailable", systemImage: "map")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(FreoSecondaryButtonStyle())
                        .frame(maxWidth: 240)
                        .disabled(store.isBusy || store.isCloudHistoryLoading)
                }
            }
        }
        .background(FreoPalette.background)
        .navigationTitle("Path")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !requested else { return }
            requested = true
            await load()
        }
    }

    private func load() async {
        isLoading = true
        run = await store.openCloudCleaningRecord(record)
        error = store.cloudHistoryError.isEmpty ? "This saved route could not be opened." : store.cloudHistoryError
        if let run, !store.cleaningHistory.contains(where: { $0.id == run.id }), !store.historyError.isEmpty {
            storageNotice = store.historyError
        } else { storageNotice = nil }
        isLoading = false
    }
}

struct CleaningRunDetailView: View {
    let run: CleaningRun
    var storageNotice: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HistorySummaryRow(mode: run.modeName, rooms: run.roomNames,
                                      date: run.startedAt, isCloudRecord: run.isCloudRecord,
                                      prominent: true)
                    if let storageNotice {
                        Text(storageNotice).font(.caption).foregroundStyle(FreoPalette.warning)
                    }
                }

                FloorplanView(floorplan: run.floorplan, selectedRoomIDs: [], isDemo: false,
                              isBusy: false, toggleRoom: { _ in },
                              route: FloorplanRouteOverlay(trajectory: run.trajectory),
                              allowsRoomSelection: false, maximumCanvasHeight: 520)

                if let reason = run.trajectory.unavailableReason, !reason.isEmpty {
                    Text(reason).font(.footnote).foregroundStyle(FreoPalette.secondaryText)
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        if !run.isCloudRecord {
                            LabeledContent("First recorded", value: run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if !run.partialReason.isEmpty {
                            Text(run.partialReason)
                        }
                        if run.trajectory.pose != nil {
                            Text("Dot: last reported position.")
                        }
                        Text("Gaps stay blank. Paths do not measure cleaned area.")
                    }
                    .font(.footnote)
                    .foregroundStyle(FreoPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } label: {
                    LabeledContent(run.isCloudRecord ? "Downloaded" : "Last recorded",
                                   value: (run.importedAt ?? run.updatedAt).formatted(date: .abbreviated, time: .shortened))
                }
                .font(.subheadline)
                .padding(16)
                .background(FreoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(16)
            .padding(.bottom, 24)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .background(FreoPalette.background)
        .navigationTitle("Path")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HistorySummaryRow: View {
    let mode: String?
    let rooms: [String]
    let date: Date
    let isCloudRecord: Bool
    var durationSeconds: Int? = nil
    var prominent = false
    var run: CleaningRun? = nil

    private var title: String { mode ?? "Cleaning mode unavailable" }
    private var symbol: String {
        let name = mode?.lowercased() ?? ""
        if name.contains("vacuum") && name.contains("mop") { return "drop.circle" }
        if name.contains("vacuum") { return "wind" }
        if name.contains("mop") { return "drop" }
        return "map"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if prominent {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(FreoPalette.accent)
                    .frame(width: 42, height: 42)
                    .background(FreoPalette.selection, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            } else {
                CleaningRouteThumbnail(run: run)
                    .frame(width: 88, height: 104)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(prominent ? .title3.weight(.semibold) : .body.weight(.semibold))
                        .foregroundStyle(FreoPalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(isCloudRecord ? "Narwal" : "Partial")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(FreoPalette.secondaryText)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(FreoPalette.fill, in: Capsule())
                        .fixedSize()
                        .accessibilityLabel(isCloudRecord ? "Narwal history" : "Partial recording")
                }
                if !rooms.isEmpty {
                    Text(rooms.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(FreoPalette.secondaryText)
                        .lineLimit(prominent ? nil : 2)
                }
                if rooms.isEmpty {
                    Text("Rooms unavailable").font(.subheadline)
                        .foregroundStyle(FreoPalette.secondaryText)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { timestamp; duration }
                    VStack(alignment: .leading, spacing: 3) { timestamp; duration }
                }
                .font(.caption)
                .foregroundStyle(FreoPalette.secondaryText)
            }
        }
        .padding(.vertical, prominent ? 0 : 6)
    }

    private var timestamp: some View {
        Text(date.formatted(date: .abbreviated, time: .shortened))
            .accessibilityLabel("\(isCloudRecord ? "Cleaning date" : "First recorded") \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    @ViewBuilder
    private var duration: some View {
        if let seconds = durationSeconds {
            Label(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)),
                  systemImage: "clock")
        }
    }
}

private extension View {
    func historyRow() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

/// A saved run's own floorplan and independent route segments. Never substitutes
/// today's map or connects gaps between observations.
struct CleaningRouteThumbnail: View {
    let run: CleaningRun?
    @Environment(\.colorScheme) private var colorScheme
    @State private var raster: FloorRaster?
    private var renderKey: String { "\(run?.id.uuidString ?? "none")|\(run?.updatedAt.timeIntervalSince1970 ?? 0)|\(colorScheme)" }
    var body: some View {
        Group {
            if let run, let raster {
                Canvas { context, size in
                    let bounds = raster.bounds
                    let scale = min((size.width - 12) / max(1, bounds.width), (size.height - 12) / max(1, bounds.height))
                    let frame = CGRect(x: (size.width - bounds.width * scale) / 2,
                                       y: (size.height - bounds.height * scale) / 2,
                                       width: bounds.width * scale, height: bounds.height * scale)
                    context.draw(Image(decorative: raster.image, scale: 1).interpolation(.none), in: frame)
                    context.clip(to: Path(frame))
                    func point(_ p: RobotPathPoint) -> CGPoint {
                        CGPoint(x: frame.minX + (CGFloat(p.x) - bounds.minX) * scale,
                                y: frame.minY + (CGFloat(p.y) - bounds.minY) * scale)
                    }
                    for segment in run.trajectory.segments {
                        guard let first = segment.points.first else { continue }
                        var path = Path(); path.move(to: point(first))
                        for p in segment.points.dropFirst() { path.addLine(to: point(p)) }
                        context.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        context.stroke(path, with: .color(FreoPalette.accent), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    }
                }
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "map").font(.title3)
                    Text("No path").font(.caption2)
                }
                .foregroundStyle(FreoPalette.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FreoPalette.fill, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(run == nil ? "Saved path unavailable" : "Saved cleaning map and route")
        .task(id: renderKey) {
            raster = run.flatMap { FloorRaster(floorplan: $0.floorplan, selected: [], dark: colorScheme == .dark, highContrast: false) }
        }
    }
}

@MainActor
struct RobotCleaningHistorySection: View {
    @EnvironmentObject private var store: FreoStore
    private enum Entry: Identifiable {
        case saved(CleaningRun), cloud(CloudCleaningRecord)
        var id: String { switch self { case .saved(let run): "saved-" + run.id.uuidString; case .cloud(let record): "cloud-" + record.id } }
        var date: Date { switch self { case .saved(let run): run.startedAt; case .cloud(let record): record.startedAt } }
    }
    private var entries: [Entry] {
        guard !store.isDemo else { return [] }
        let records = store.cloudCleaningRecords.filter { record in
            store.selectedDevice.map { record.matches(device: $0) } ?? false
        }
        let saved = store.cleaningHistory.filter { run in
            let matches = store.selectedDevice.map { $0.id == run.trajectory.deviceID && $0.productKey == run.trajectory.productKey } ?? true
            return matches && !records.contains { $0.id == run.cloudRecordID }
        }
        return (records.map(Entry.cloud) + saved.map(Entry.saved)).sorted { $0.date > $1.date }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cleaning history").font(.headline)
                Spacer()
                if store.isAuthenticated && !store.isDemo {
                    HistorySyncButton(isLoading: store.isCloudHistoryLoading,
                                      isCancelling: store.isCloudHistoryCancelling, isBusy: store.isBusy) {
                        Task { await store.loadCloudHistory() }
                    } cancel: { store.cancelCloudHistorySync() }
                }
                NavigationLink("See all") { CleaningHistoryView() }
                    .font(.subheadline)
            }
            if entries.isEmpty {
                Text(store.isHistoryLoading ? "Loading history…" : "No cleaning history yet.")
                    .font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(entries.prefix(10))) { entry in
                    NavigationLink {
                        switch entry {
                        case .saved(let run): CleaningRunDetailView(run: run)
                        case .cloud(let record): CloudCleaningDetailView(record: record)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            switch entry {
                            case .saved(let run):
                                HistorySummaryRow(mode: run.modeName, rooms: run.roomNames,
                                                  date: run.startedAt, isCloudRecord: run.isCloudRecord, run: run)
                            case .cloud(let record):
                                HistorySummaryRow(mode: record.modeName, rooms: record.roomNames,
                                                  date: record.startedAt, isCloudRecord: true,
                                                  durationSeconds: record.durationSeconds,
                                                  run: store.cleaningHistory.first {
                                                      $0.cloudRecordID == record.id && $0.trajectory.deviceID == record.deviceID &&
                                                          $0.trajectory.productKey == record.productKey
                                                  })
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(FreoPalette.secondaryText)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if entry.id != entries.prefix(10).last?.id { Divider() }
                }
            }
        }
        .freoCard()
        .task(id: store.isAuthenticated ? store.selectedDeviceID : nil) {
            await store.loadCleaningHistory()
            if store.isAuthenticated && store.cloudCleaningRecords.isEmpty && !store.isBusy && store.status?.workingCode == 1 {
                await store.loadCloudHistory()
            }
        }
    }
}
