import SwiftUI

struct RoomEditorView: View {
    var initialRoomIDs: Set<Int> = []
    @EnvironmentObject private var store: FreoStore
    @Environment(\.dismiss) private var dismiss
    @State private var map: Floorplan?
    @State private var sources: Set<Int> = []
    @State private var editing = false
    @State private var corner = 3
    @State private var cutX = 0
    @State private var cutY = 0
    @State private var drawnBox: RoomGridRectangle?
    @State private var kitchenName = "New room"
    @State private var hallwayName = "Remaining area"
    @State private var error = ""
    @State private var saved = false
    @State private var savedNamesOnly = false
    @State private var savedMerge = false
    @State private var showingMergeConfirmation = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var resumeOnly = false
    private enum NameField: Hashable { case kitchen, hallway }
    @FocusState private var editingName: NameField?

    private var bounds: RoomGridRectangle? {
        guard let map else { return nil }
        return try? RoomPartitionPlanner.sourceBounds(floorplan: map, sourceRoomIDs: sources)
    }
    private var rectangle: RoomGridRectangle? {
        guard let b = bounds else { return nil }
        if let drawnBox { return drawnBox }
        let right = corner % 2 == 1, bottom = corner >= 2
        return RoomGridRectangle(minX: right ? cutX : b.minX, minY: bottom ? cutY : b.minY,
                                 maxXExclusive: right ? b.maxXExclusive : cutX,
                                 maxYExclusive: bottom ? b.maxYExclusive : cutY)
    }
    private var proposal: Result<RoomPartitionPlan, Error>? {
        guard let map, let rectangle else { return nil }
        return Result {
            let candidate = try RoomPartitionPlanner.makeBox(floorplan: map, sourceRoomIDs: sources, rectangle: rectangle)
            let stage = try RoomPartitionTransaction.remainingStage(plan: candidate, floorplan: map)
            if resumeOnly && stage == .wholeArea {
                throw ConnectorError.invalid("The selected layout does not match a saved step. Adjust the boundaries to the existing divisions before continuing.")
            }
            return candidate
        }
    }
    private var plan: RoomPartitionPlan? { try? proposal?.get() }
    private var validation: String? {
        guard let proposal else { return "Choose the area to reshape." }
        if case .failure(let failure) = proposal { return failure.localizedDescription }
        return nil
    }
    private var nameError: String? {
        let a = kitchenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = hallwayName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try NarwalCodec.validateRoomName(a)
            try NarwalCodec.validateRoomName(b)
        } catch { return error.localizedDescription }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            ? "Give the two rooms different names." : nil
    }
    private var saveBlocker: String? { validation ?? nameError }
    private var canSave: Bool { !isSaving && !store.isBusy && saveBlocker == nil && plan != nil }
    private var remainingStage: RoomPartitionRemainingStage? {
        guard let map, let plan else { return nil }
        return try? RoomPartitionTransaction.remainingStage(plan: plan, floorplan: map)
    }
    private var saveTitle: String {
        if isSaving { return "Saving…" }
        if store.isDemo { return "Apply to demo" }
        if remainingStage == .finalPartitionSaved { return "Save room names" }
        if resumeOnly || remainingStage == .horizontalDividerSaved || remainingStage == .threePiecesSaved {
            return "Continue saving"
        }
        return "Save to robot"
    }
    private var selectedNames: String {
        map?.rooms.filter { sources.contains($0.id) }.map(\.name).joined(separator: " + ") ?? ""
    }
    private var mergeError: String? {
        guard let map, sources.count == 2 else { return nil }
        do { try RoomMergeTransaction.validate(floorplan: map, sourceRoomIDs: sources); return nil }
        catch { return error.localizedDescription }
    }
    private var mergedName: String {
        map?.rooms.first(where: { $0.id == sources.min() })?.name ?? "the first room"
    }

    var body: some View {
        NavigationStack {
            Form {
                if saved {
                    Section {
                        Label(store.isDemo ? "Demo floorplan updated" : savedMerge ? "Rooms merged" : savedNamesOnly ? "Room names verified" : "Room boundaries verified", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(FreoPalette.success)
                        Text(store.isDemo ? "No robot was contacted." : savedMerge ? "Select the combined room to set new boundaries." : savedNamesOnly ? "Existing boundaries were preserved. Cleaning performance still needs a physical check." : "The saved map matches your two rooms. Cleaning performance still needs a physical check.")
                            .font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
                    }
                } else if let map {
                    if editing, let b = bounds, let rectangle {
                        boundarySections(map: map, bounds: b, rectangle: rectangle)
                    } else {
                        Section {
                            ForEach(map.roomsWithArea) { room in
                                Button { toggleSource(room.id) } label: {
                                    HStack {
                                        Text(room.name).font(.body).foregroundStyle(FreoPalette.primaryText)
                                        Spacer()
                                        Image(systemName: sources.contains(room.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(sources.contains(room.id) ? FreoPalette.accent : FreoPalette.secondaryText)
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityAddTraits(sources.contains(room.id) ? .isSelected : [])
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                .listRowSeparatorTint(FreoPalette.separator)
                                .disabled(store.isBusy || isSaving || (!sources.contains(room.id) && sources.count >= 8))
                            }
                            Button("Deselect all") {
                                sources = []
                                kitchenName = "New room"
                                hallwayName = "Remaining area"
                                resetCuts()
                            }
                            .frame(minHeight: 44)
                            .disabled(store.isBusy || isSaving)
                        } header: { Text("Select rooms") }
                        footer: { Text("Select two adjoining rooms to merge, or choose an area to set new boundaries.") }
                    }
                } else if isLoading {
                    Section { HStack(spacing: 12) { ProgressView(); Text("Loading room boundaries…") } }
                }
                if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.primary)
                        if !store.isBusy && !saved {
                            Button("Reload map") { Task { await load() } }
                        }
                    }
                }
            }
            .tint(FreoPalette.accent)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editing && !saved ? "Room boundaries" : "Edit rooms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if editing && !saved {
                        Button("Back") { editingName = nil; editing = false }.disabled(isSaving)
                    } else if !saved {
                        Button("Cancel") { dismiss() }.disabled(isSaving)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saved {
                        Button("Done") { dismiss() }
                    } else if editing {
                        Button("Close") { dismiss() }.disabled(isSaving)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editingName = nil }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !saved, map != nil {
                    actionBar
                }
            }
            .interactiveDismissDisabled(isSaving)
            .confirmationDialog("Merge \(selectedNames)?", isPresented: $showingMergeConfirmation, titleVisibility: .visible) {
                Button("Merge rooms") { Task { await merge() } }
            } message: {
                Text("Remove their shared boundary and keep the name \(mergedName).")
            }
            .task {
                store.roomEditorPresented(true)
                if map == nil { await load() }
            }
            .onDisappear { store.roomEditorPresented(false) }
        }
    }

    @ViewBuilder
    private func boundarySections(map: Floorplan, bounds b: RoomGridRectangle, rectangle: RoomGridRectangle) -> some View {
        Section {
            RoomPartitionCanvas(floorplan: map, sourceRoomIDs: sources, rectangle: rectangle,
                                sourceBounds: b, plan: plan, onDraw: { drawnBox = $0 },
                                disabled: isSaving)
                .frame(height: 300)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                Label(kitchenName.isEmpty ? "Rectangle" : kitchenName, systemImage: "square.fill").foregroundStyle(RoomEditorColors.kitchen)
                Label(hallwayName.isEmpty ? "Remaining area" : hallwayName, systemImage: "square.fill").foregroundStyle(FreoPalette.accent)
            }
            .font(.caption.weight(.medium))
            .accessibilityElement(children: .combine)
            if let summary = plan?.boxOperationSummary {
                Label(summary, systemImage: "arrow.triangle.merge")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(FreoPalette.secondaryText)
            }
        } header: { Text(selectedNames) }
        footer: { Text("Drag on the map to draw a box. Drag inside it to move it, or use the handle to resize it.") }

        Section {
            LabeledContent("Rectangle") {
                TextField("Name", text: $kitchenName).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Rectangle room name")
                    .focused($editingName, equals: .kitchen)
            }
            LabeledContent("Remaining area") {
                TextField("Name", text: $hallwayName).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Remaining room name")
                    .focused($editingName, equals: .hallway)
            }
        } header: { Text("Room names") }
        .textInputAutocapitalization(.words).autocorrectionDisabled()
        .disabled(isSaving)

        if !store.isDemo {
            Section {
                DisclosureGroup("Saving room changes") {
                    Text("Room edits are experimental and save in steps. After a partial save, reload the map and review the remaining layout. Already matching divisions are kept. There is no automatic rollback.")
                        .font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editing {
                if isSaving {
                    Text(store.roomEditProgress.isEmpty ? "Checking robot and saving…" : store.roomEditProgress)
                        .font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
                } else if let reason = saveBlocker {
                    Text(reason).font(.subheadline).foregroundStyle(FreoPalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Cannot save. \(reason)")
                } else if store.isBusy {
                    Text("Waiting for the current request…").font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
                } else if !store.isDemo && remainingStage == .finalPartitionSaved {
                    Text("Only the room names will change.").font(.subheadline).foregroundStyle(FreoPalette.secondaryText)
                }
                Button {
                    guard let plan else { return }
                    editingName = nil
                    Task { await save(plan) }
                } label: {
                    HStack {
                        if isSaving { ProgressView().tint(FreoPalette.onAccent) }
                        Text(saveTitle).font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .foregroundStyle(FreoPalette.onAccent)
                .disabled(!canSave)
            } else {
                Button { editing = true } label: {
                    Text("Set boundaries").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .foregroundStyle(FreoPalette.onAccent)
                .disabled(bounds == nil || store.isBusy || isSaving)
                if sources.count == 2 {
                    if let mergeError {
                        Text(mergeError).font(.footnote).foregroundStyle(FreoPalette.secondaryText)
                    }
                    Button {
                        showingMergeConfirmation = true
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving { ProgressView() }
                            Text(isSaving ? "Merging…" : "Merge rooms")
                        }
                    }
                    .buttonStyle(FreoSecondaryButtonStyle())
                    .disabled(store.isBusy || isSaving || mergeError != nil)
                }
            }
        }
        .buttonStyle(FreoPrimaryButtonStyle())
        .tint(FreoPalette.buttonFill)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func toggleSource(_ id: Int) {
        if sources.contains(id) { sources.remove(id) } else if sources.count < 8 { sources.insert(id) }
        kitchenName = "New room"
        hallwayName = sources.count == 1 ? (map?.rooms.first(where: { sources.contains($0.id) })?.name ?? "Remaining area") : "Remaining area"
        resetCuts()
    }
    private func resetCuts() {
        drawnBox = nil
        if let b = bounds {
            cutX = (b.minX + b.maxXExclusive) / 2
            cutY = (b.minY + b.maxYExclusive) / 2
            // A reviewed final partition needs names only. Reuse its existing
            // corner instead of requiring the user to find the same grid cell.
            guard let map, sources.count == 2 else { return }
            var matches: [(corner: Int, x: Int, y: Int)] = []
            for id in sources.sorted() {
                guard let roomBounds = try? RoomPartitionPlanner.sourceBounds(floorplan: map, sourceRoomIDs: [id]) else { continue }
                for candidateCorner in 0..<4 {
                    let right = candidateCorner % 2 == 1, bottom = candidateCorner >= 2
                    let x = right ? roomBounds.minX : roomBounds.maxXExclusive
                    let y = bottom ? roomBounds.minY : roomBounds.maxYExclusive
                    let rectangle = RoomGridRectangle(minX: right ? x : b.minX, minY: bottom ? y : b.minY,
                        maxXExclusive: right ? b.maxXExclusive : x, maxYExclusive: bottom ? b.maxYExclusive : y)
                    guard let candidate = try? RoomPartitionPlanner.make(floorplan: map, sourceRoomIDs: sources, rectangle: rectangle),
                          (try? RoomPartitionTransaction.remainingStage(plan: candidate, floorplan: map)) == .finalPartitionSaved else { continue }
                    if !matches.contains(where: { $0.corner == candidateCorner && $0.x == x && $0.y == y }) {
                        matches.append((candidateCorner, x, y))
                    }
                }
            }
            if matches.count == 1, let match = matches.first {
                corner = match.corner; cutX = match.x; cutY = match.y
                if let rectangle,
                   let candidate = try? RoomPartitionPlanner.make(floorplan: map, sourceRoomIDs: sources, rectangle: rectangle),
                   let ids = try? candidate.recognizedFinalPartition(map), ids.count == 2 {
                    kitchenName = map.rooms.first(where: { $0.id == ids[0] })?.name ?? "New room"
                    hallwayName = map.rooms.first(where: { $0.id == ids[1] })?.name ?? "Remaining area"
                }
            }
        }
    }
    private func load() async {
        error = ""; saved = false; savedMerge = false; map = nil; sources = []; editing = false
        isLoading = true; defer { isLoading = false }
        do {
            let current = try await store.prepareRoomEditing()
            guard initialRoomIDs.isSubset(of: Set(current.rooms.map(\.id))), initialRoomIDs.count <= 8 else {
                throw ConnectorError.invalid("The selected rooms changed. Close the editor and select them again on the map.")
            }
            map = current
            sources = initialRoomIDs
            kitchenName = "New room"
            hallwayName = sources.count == 1
                ? current.rooms.first(where: { sources.contains($0.id) })?.name ?? "Remaining area"
                : "Remaining area"
            resetCuts()
            editing = !sources.isEmpty
        } catch { self.error = error.localizedDescription }
    }
    private func save(_ plan: RoomPartitionPlan) async {
        error = ""; isSaving = true
        savedNamesOnly = remainingStage == .finalPartitionSaved
        defer { isSaving = false }
        do {
            try await store.saveRoomPartition(plan, kitchenName: kitchenName, hallwayName: hallwayName, resumeOnly: resumeOnly)
            saved = true
        } catch {
            if error is RoomPartitionTransactionError { resumeOnly = true }
            self.error = error.localizedDescription; self.map = nil
        }
    }
    private func merge() async {
        guard let reviewed = map, sources.count == 2 else { return }
        let selected = sources
        error = ""; isSaving = true; savedNamesOnly = false; savedMerge = false
        defer { isSaving = false }
        do {
            try await store.saveRoomMerge(selected, baseline: reviewed)
            savedMerge = true; saved = true
        } catch {
            self.error = error.localizedDescription
            self.map = nil
        }
    }
}

private enum RoomEditorColors {
    static let kitchen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 140 / 255, green: 173 / 255, blue: 219 / 255, alpha: 1)
            : UIColor(red: 70 / 255, green: 105 / 255, blue: 159 / 255, alpha: 1)
    })
}

private struct RoomPartitionCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    @GestureState private var isDragging = false
    @State private var dragStart: RoomGridRectangle?
    @State private var dragBox: RoomGridRectangle?
    let floorplan: Floorplan
    let sourceRoomIDs: Set<Int>
    let rectangle: RoomGridRectangle
    let sourceBounds: RoomGridRectangle
    let plan: RoomPartitionPlan?
    let onDraw: (RoomGridRectangle) -> Void
    let disabled: Bool

    var body: some View {
        GeometryReader { proxy in
            let viewport = CGRect(x: sourceBounds.minX - 5, y: sourceBounds.minY - 5,
                                  width: sourceBounds.maxXExclusive - sourceBounds.minX + 10,
                                  height: sourceBounds.maxYExclusive - sourceBounds.minY + 10)
            let scale = min(proxy.size.width / viewport.width, proxy.size.height / viewport.height)
            let origin = CGPoint(x: (proxy.size.width - viewport.width * scale) / 2,
                                 y: (proxy.size.height - viewport.height * scale) / 2)
            let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
                CGPoint(x: origin.x + (x - viewport.minX) * scale, y: origin.y + (y - viewport.minY) * scale)
            }
            let preview = dragBox ?? plan?.rectangle ?? rectangle
            let handleCenter = point(CGFloat(preview.maxXExclusive), CGFloat(preview.maxYExclusive))
            Canvas { context, _ in
                if let raster = FloorRaster(floorplan: floorplan, selected: [], dark: colorScheme == .dark, highContrast: false) {
                    let start = point(raster.bounds.minX, raster.bounds.minY)
                    context.draw(Image(decorative: raster.image, scale: 1).interpolation(.none),
                                 in: CGRect(origin: start, size: CGSize(width: raster.bounds.width * scale, height: raster.bounds.height * scale)))
                }
                var kitchen = Path(), hallway = Path(), overlap = Path()
                let knownRoomIDs = Set(floorplan.rooms.map(\.id))
                for (index, raw) in floorplan.pixels.enumerated() {
                    let pixel = MapPixel(rawValue: raw)
                    let roomID = pixel.roomID
                    guard roomID != 0 else { continue }
                    let x = index % floorplan.width, y = floorplan.height - 1 - index / floorplan.width
                    let rect = CGRect(origin: point(CGFloat(x), CGFloat(y)), size: CGSize(width: scale, height: scale))
                    let inside = preview.contains(x: x, y: y)
                    if sourceRoomIDs.contains(roomID) {
                        if inside { kitchen.addRect(rect) } else { hallway.addRect(rect) }
                    } else if inside && !(knownRoomIDs.contains(roomID) && pixel.isUnreachable) { overlap.addRect(rect) }
                }
                context.fill(hallway, with: .color(FreoPalette.accent.opacity(0.3)))
                context.fill(kitchen, with: .color(RoomEditorColors.kitchen.opacity(0.4)))
                context.fill(overlap, with: .color(.red.opacity(0.6)))
                let rectOrigin = point(CGFloat(preview.minX), CGFloat(preview.minY))
                let rect = CGRect(origin: rectOrigin, size: CGSize(width: CGFloat(preview.width) * scale,
                                                                  height: CGFloat(preview.height) * scale))
                context.stroke(Path(rect), with: .color(dragBox == nil && plan == nil ? .red : RoomEditorColors.kitchen),
                               style: StrokeStyle(lineWidth: 2, dash: dragBox == nil && plan == nil ? [5, 3] : []))
                let elbow = handleCenter
                let handle = Path(ellipseIn: CGRect(x: elbow.x - 10, y: elbow.y - 10, width: 20, height: 20))
                context.fill(handle, with: .color(FreoPalette.surface))
                context.stroke(handle, with: .color(FreoPalette.accent), lineWidth: 3)
            }
            .clipped()
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .allowsHitTesting(!disabled)
                    .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("room-edit-map"))
                    .updating($isDragging) { _, active, _ in active = true }
                    .onChanged { value in
                        guard !disabled else { return }
                        let start = dragStart ?? rectangle
                        dragStart = start
                        let dx = Int((value.translation.width / scale).rounded())
                        let dy = Int((value.translation.height / scale).rounded())
                        let anchor = point(CGFloat(start.maxXExclusive), CGFloat(start.maxYExclusive))
                        let original = CGRect(origin: point(CGFloat(start.minX), CGFloat(start.minY)),
                            size: CGSize(width: CGFloat(start.width) * scale, height: CGFloat(start.height) * scale))
                        if abs(value.startLocation.x - anchor.x) <= 22 && abs(value.startLocation.y - anchor.y) <= 22 {
                            dragBox = .init(minX: start.minX, minY: start.minY,
                                maxXExclusive: min(sourceBounds.maxXExclusive, max(start.minX + 1, start.maxXExclusive + dx)),
                                maxYExclusive: min(sourceBounds.maxYExclusive, max(start.minY + 1, start.maxYExclusive + dy)))
                        } else if original.contains(value.startLocation) {
                            let x = min(sourceBounds.maxXExclusive - start.width, max(sourceBounds.minX, start.minX + dx))
                            let y = min(sourceBounds.maxYExclusive - start.height, max(sourceBounds.minY, start.minY + dy))
                            dragBox = .init(minX: x, minY: y, maxXExclusive: x + start.width, maxYExclusive: y + start.height)
                        } else {
                            func grid(_ p: CGPoint) -> RoomGridPoint {
                                .init(x: min(sourceBounds.maxXExclusive, max(sourceBounds.minX, Int(((p.x - origin.x) / scale + viewport.minX).rounded()))),
                                      y: min(sourceBounds.maxYExclusive, max(sourceBounds.minY, Int(((p.y - origin.y) / scale + viewport.minY).rounded()))))
                            }
                            let a = grid(value.startLocation), b = grid(value.location)
                            if a.x != b.x && a.y != b.y {
                                dragBox = .init(minX: min(a.x, b.x), minY: min(a.y, b.y),
                                             maxXExclusive: max(a.x, b.x), maxYExclusive: max(a.y, b.y))
                            }
                        }
                    }
                    .onEnded { _ in
                        if let dragBox, !disabled { onDraw(dragBox) }
                        dragBox = nil
                    })
            }
            .coordinateSpace(name: "room-edit-map")
            .onChange(of: isDragging) { _, active in
                if !active { dragStart = nil; dragBox = nil }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Room boundary preview")
            .accessibilityHint("Drag to draw a box, drag inside to move it, or drag its handle to resize it.")
        }
        .background(FreoPalette.background)
    }
}
