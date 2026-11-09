import SwiftUI
import CoreGraphics
import UIKit

/// Display-grid coordinates: origin at the raster's top-left, y increasing down.
/// Each segment is independent; the view never joins a missing observation.
struct FloorplanRouteOverlay {
    struct Segment {
        enum Kind { case cleaning, edge, travel, unknown }
        let points: [CGPoint]
        let kind: Kind
    }
    let segments: [Segment]
    let robotPosition: CGPoint?

    init(trajectory: RobotTrajectory, showsRobotPosition: Bool = true) {
        segments = trajectory.segments.map { segment in
            let kind: Segment.Kind = switch segment.typeCode {
            case 4: .cleaning
            case 2, 3: .edge
            case 1: .travel
            default: .unknown
            }
            return Segment(points: segment.points.map { CGPoint(x: $0.x, y: $0.y) }, kind: kind)
        }
        robotPosition = showsRobotPosition ? trajectory.pose.map { CGPoint(x: $0.point.x, y: $0.point.y) } : nil
    }
}

struct FloorplanView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorContrast
    let floorplan: Floorplan
    let selectedRoomIDs: Set<Int>
    let isDemo: Bool
    let isBusy: Bool
    let toggleRoom: (Int) -> Void
    var route: FloorplanRouteOverlay? = nil
    var allowsRoomSelection = true
    var taskRoomIDs: Set<Int> = []
    var robotRoomID: Int? = nil
    var maximumCanvasHeight: CGFloat? = nil
    var onEditRooms: (() -> Void)? = nil
    var onRenameRooms: (() -> Void)? = nil
    var onMapUpdates: (() -> Void)? = nil

    @State private var raster: FloorRaster?
    @State private var availableWidth: CGFloat = 340
    @State private var showingRoomNames = true
    @State private var rotated = false
    @State private var showingMapKey = false

    private var knownRoomIDs: Set<Int> { Set(floorplan.rooms.map(\.id)) }
    private var visibleTaskRoomIDs: Set<Int> {
        taskRoomIDs.intersection(knownRoomIDs)
    }
    private var visibleRobotRoomID: Int? {
        guard let robotRoomID, knownRoomIDs.contains(robotRoomID) else { return nil }
        return robotRoomID
    }

    private var canvasHeight: CGFloat {
        guard let raster else { return 320 }
        return min(max(220, maximumCanvasHeight ?? 680),
                   max(260, availableWidth * raster.bounds.height / max(1, raster.bounds.width)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let raster {
                GeometryReader { proxy in
                    let layout = FloorLayout(raster: raster, size: proxy.size, rotated: rotated,
                                             robotRoomID: visibleRobotRoomID,
                                             selectedRoomIDs: allowsRoomSelection ? selectedRoomIDs : [],
                                             verticalInset: allowsRoomSelection ? 8 : 18,
                                             reservedLabelArea: CGRect(x: proxy.size.width - 60, y: 0, width: 60, height: 60))
                    Canvas { context, _ in
                        drawMap(context: &context, layout: layout, raster: raster)
                    }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        handleTap(event.location, layout: layout)
                    })
                    .accessibilityElement(children: allowsRoomSelection ? .contain : .ignore)
                    .accessibilityLabel(isDemo ? "Synthetic demo floorplan" : "Saved robot floorplan")
                    .accessibilityValue(accessibilitySummary)
                    .accessibilityHint(allowsRoomSelection ? "Double-tap a room to select it." : "Read-only map. Robot position and task rooms are separate.")
                    .accessibilityChildren {
                        if allowsRoomSelection {
                            ForEach(floorplan.rooms) { room in
                                Button(room.name) { toggleRoom(room.id) }
                                    .accessibilityValue(selectedRoomIDs.contains(room.id) ? "Selected" : "Not selected")
                                    .accessibilityAddTraits(selectedRoomIDs.contains(room.id) ? .isSelected : [])
                                    .disabled(isBusy)
                            }
                        }
                    }
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
                }
                .frame(height: canvasHeight)
                .background(FreoPalette.background)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "map").font(.title)
                    Text("The saved floorplan could not be drawn.")
                        .font(.subheadline).multilineTextAlignment(.center)
                }
                .foregroundStyle(FreoPalette.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 240)
                .background(FreoPalette.background)
            }

        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            Menu {
                if let onEditRooms {
                    Button(action: onEditRooms) {
                        Label(selectedRoomIDs.count == 1 ? "Edit room" : "Edit rooms", systemImage: "rectangle.split.2x2")
                    }
                    .disabled(isBusy || selectedRoomIDs.isEmpty || selectedRoomIDs.count > 8)
                }
                if let onRenameRooms {
                    Button(action: onRenameRooms) {
                        Label(selectedRoomIDs.count == 1 ? "Rename room" : "Rename rooms", systemImage: "pencil")
                    }
                    .disabled(isBusy || selectedRoomIDs.isEmpty)
                }
                if onEditRooms != nil || onRenameRooms != nil { Divider() }
                Toggle(isOn: $showingRoomNames) {
                    Label("Room labels", systemImage: "tag")
                }
                Button { rotated.toggle() } label: {
                    Label("Rotate map", systemImage: "rotate.right")
                }
                .accessibilityValue(rotated ? "Rotated 180 degrees" : "Original orientation")
                Button { showingMapKey = true } label: {
                    Label("Map legend", systemImage: "list.bullet.rectangle")
                }
                if let onMapUpdates {
                    Button(action: onMapUpdates) {
                        Label("Map updates", systemImage: "network")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(FreoIconButtonStyle())
            .accessibilityLabel("Map menu")
            .padding(8)
        }
        .sheet(isPresented: $showingMapKey) {
            NavigationStack {
                ScrollView {
                    RouteLegend(hasRoute: route != nil,
                                showsRobotPosition: route?.robotPosition != nil,
                                showsTaskRooms: !visibleTaskRoomIDs.isEmpty,
                                showsRobotRoom: visibleRobotRoomID != nil,
                                showsSelection: allowsRoomSelection)
                        .padding(24)
                }
                    .navigationTitle("Map legend")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingMapKey = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear { refreshRaster() }
        .onChange(of: colorScheme) { _, _ in refreshRaster() }
        .onChange(of: colorContrast) { _, _ in refreshRaster() }
        .onChange(of: selectedRoomIDs) { _, _ in refreshRaster() }
        .onChange(of: taskRoomIDs) { _, _ in refreshRaster() }
        .onChange(of: robotRoomID) { _, _ in refreshRaster() }
        .onChange(of: allowsRoomSelection) { _, _ in refreshRaster() }
        .onChange(of: floorplan) { _, _ in
            refreshRaster()
        }
    }

    private func refreshRaster() {
        var outlined = visibleTaskRoomIDs
        if let roomID = visibleRobotRoomID { outlined.insert(roomID) }
        raster = FloorRaster(floorplan: floorplan, selected: allowsRoomSelection ? selectedRoomIDs : [],
                             dark: colorScheme == .dark, highContrast: colorContrast == .increased,
                             outlinedRoomIDs: outlined, taskRoomIDs: visibleTaskRoomIDs)
    }

    private var accessibilitySummary: String {
        var parts = [floorplan.rooms.map(\.name).joined(separator: ", ")]
        if allowsRoomSelection {
            let selected = floorplan.rooms.filter { selectedRoomIDs.contains($0.id) }.map(\.name)
            parts.append(selected.isEmpty ? "No rooms selected" : "Selected rooms: " + selected.joined(separator: ", "))
        }
        let task = floorplan.rooms.filter { visibleTaskRoomIDs.contains($0.id) }.map(\.name)
        if !task.isEmpty { parts.append("Current task rooms: " + task.joined(separator: ", ")) }
        if let room = floorplan.rooms.first(where: { $0.id == visibleRobotRoomID }) {
            parts.append("Robot reported in " + room.name)
        }
        if let route {
            parts.append("\(route.segments.count) reported path segments")
            if route.robotPosition != nil { parts.append("Last reported robot position marked") }
        }
        if rotated { parts.append("View rotated 180 degrees") }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func handleTap(_ location: CGPoint, layout: FloorLayout) {
        guard allowsRoomSelection, !isBusy else { return }
        let mapPoint = layout.mapPoint(location)
        if showingRoomNames, let label = layout.labels.first(where: { $0.rect.insetBy(dx: -4, dy: -6).contains(location) }) {
            toggleRoom(label.roomID)
            return
        }
        guard mapPoint.x >= 0, mapPoint.x < CGFloat(floorplan.width),
              mapPoint.y >= 0, mapPoint.y < CGFloat(floorplan.height) else { return }
        let x = Int(mapPoint.x), row = floorplan.height - 1 - Int(mapPoint.y)
        let index = row * floorplan.width + x
        guard floorplan.pixels.indices.contains(index) else { return }
        let pixel = MapPixel(rawValue: floorplan.pixels[index])
        if let roomID = pixel.knownRoomID(in: Set(floorplan.rooms.map(\.id))) { toggleRoom(roomID) }
    }

    private func drawMap(context: inout GraphicsContext, layout: FloorLayout, raster: FloorRaster) {
        var imageContext = context
        if rotated {
            imageContext.translateBy(x: layout.imageRect.midX, y: layout.imageRect.midY)
            imageContext.rotate(by: .degrees(180))
            imageContext.translateBy(x: -layout.imageRect.midX, y: -layout.imageRect.midY)
        }
        imageContext.draw(Image(decorative: raster.image, scale: 1).interpolation(.none), in: layout.imageRect)
        drawRoomEmphasis(context: &context, layout: layout, raster: raster)
        drawRoute(context: &context, layout: layout)
        for label in showingRoomNames ? layout.labels : [] {
            if hypot(label.rect.midX - label.anchor.x, label.rect.midY - label.anchor.y) > 12 {
                var line = Path()
                line.move(to: label.anchor)
                line.addLine(to: CGPoint(x: label.rect.midX, y: label.rect.midY))
                context.stroke(line, with: .color(FreoPalette.secondaryText.opacity(0.7)), lineWidth: 0.8)
                context.fill(Path(ellipseIn: CGRect(x: label.anchor.x - 2, y: label.anchor.y - 2, width: 4, height: 4)),
                             with: .color(FreoPalette.secondaryText))
            }
        }
        for label in showingRoomNames ? layout.labels : [] {
            let selected = allowsRoomSelection && selectedRoomIDs.contains(label.roomID)
            let taskRoom = visibleTaskRoomIDs.contains(label.roomID)
            let robotRoom = visibleRobotRoomID == label.roomID
            // A filled checkmarked label is a draft selection. The current
            // cleaning task keeps its separate map outline during selection.
            let filled = selected || (!allowsRoomSelection && taskRoom)
            let badge = Path(roundedRect: label.rect, cornerRadius: 7)
            context.fill(badge, with: .color(filled ? FreoPalette.buttonFill : FreoPalette.surface))
            context.stroke(badge, with: .color(robotRoom ? FreoPalette.accent : filled ? FreoPalette.primaryText.opacity(0.35) : FreoPalette.separator),
                           lineWidth: robotRoom ? 2.5 : colorContrast == .increased ? 2 : filled ? 1.5 : 0.75)
            let text = Text(label.name).font(.system(size: 12, weight: .medium))
                .foregroundColor(filled ? FreoPalette.onAccent : FreoPalette.primaryText)
            var nameRect = label.rect.insetBy(dx: 8, dy: 6)
            if robotRoom { nameRect.size.height -= 16 }
            if selected {
                let check = Text(Image(systemName: "checkmark.circle.fill"))
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(FreoPalette.onAccent)
                context.draw(check, in: CGRect(x: nameRect.minX, y: nameRect.midY - 7, width: 14, height: 14))
                nameRect.origin.x += 18
                nameRect.size.width -= 18
            }
            context.draw(text, in: nameRect)
            if robotRoom {
                let marker = Text("Robot").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(filled ? FreoPalette.onAccent : FreoPalette.accent)
                context.draw(marker, in: CGRect(x: label.rect.minX + 8, y: label.rect.maxY - 21,
                                               width: label.rect.width - 16, height: 14))
            }
        }
        if let point = route?.robotPosition {
            let position = layout.viewPoint(point)
            let outer = CGRect(x: position.x - 8, y: position.y - 8, width: 16, height: 16)
            context.fill(Path(ellipseIn: outer), with: .color(FreoPalette.surface))
            context.stroke(Path(ellipseIn: outer), with: .color(FreoPalette.primaryText), lineWidth: 1.5)
            context.fill(Path(ellipseIn: outer.insetBy(dx: 4, dy: 4)), with: .color(FreoPalette.accent))
        }
    }

    private func drawRoomEmphasis(context: inout GraphicsContext, layout: FloorLayout, raster: FloorRaster) {
        for roomID in visibleTaskRoomIDs.sorted() {
            guard let outline = raster.roomOutlines[roomID] else { continue }
            let path = layout.viewPath(outline)
            context.stroke(path, with: .color(FreoPalette.surface.opacity(0.95)), lineWidth: 4.5)
            context.stroke(path, with: .color(FreoPalette.accent), lineWidth: colorContrast == .increased ? 3 : 2)
        }
        if let roomID = visibleRobotRoomID, let outline = raster.roomOutlines[roomID] {
            let path = layout.viewPath(outline)
            context.stroke(path, with: .color(FreoPalette.surface), lineWidth: 6)
            context.stroke(path, with: .color(FreoPalette.accent), lineWidth: colorContrast == .increased ? 4 : 3.5)
        }
    }

    private func drawRoute(context: inout GraphicsContext, layout: FloorLayout) {
        guard let route else { return }
        var clipped = context
        clipped.clip(to: Path(layout.imageRect))
        for segment in route.segments {
            guard let first = segment.points.first else { continue }
            var path = Path()
            path.move(to: layout.viewPoint(first))
            for point in segment.points.dropFirst() { path.addLine(to: layout.viewPoint(point)) }
            let dash: [CGFloat] = switch segment.kind {
            case .cleaning: []
            case .edge: [8, 2]
            case .travel: [5, 4]
            case .unknown: [1, 4]
            }
            let stroke = StrokeStyle(lineWidth: colorContrast == .increased ? 2.5 : 1.7,
                                     lineCap: .round, lineJoin: .round, dash: dash)
            if segment.points.count == 1 {
                let point = layout.viewPoint(first)
                let rect = CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)
                clipped.fill(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(FreoPalette.surface))
                clipped.fill(Path(ellipseIn: rect), with: .color(FreoPalette.primaryText))
            } else {
                clipped.stroke(path, with: .color(FreoPalette.surface.opacity(0.9)),
                               style: StrokeStyle(lineWidth: stroke.lineWidth + 2,
                                                  lineCap: .round, lineJoin: .round, dash: dash))
                clipped.stroke(path, with: .color(FreoPalette.primaryText), style: stroke)
            }
        }
    }
}

private struct RouteLegend: View {
    let hasRoute: Bool
    let showsRobotPosition: Bool
    let showsTaskRooms: Bool
    let showsRobotRoom: Bool
    let showsSelection: Bool
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)],
                  alignment: .leading, spacing: 8) { items }
        .font(.caption).foregroundStyle(FreoPalette.secondaryText)
    }

    @ViewBuilder private var items: some View {
        if showsSelection {
            Label("Selected rooms", systemImage: "checkmark.circle.fill")
                .foregroundStyle(FreoPalette.accent)
        }
        if hasRoute {
            item("Cleaning", dash: [])
            item("Edges", dash: [8, 2])
            item("Travel", dash: [5, 4])
            item("Unclassified", dash: [1, 4])
        }
        if showsTaskRooms { roomItem("Current task", width: 2) }
        if showsRobotRoom { roomItem("Robot’s room", width: 3.5) }
        if showsRobotPosition {
            HStack(spacing: 6) {
                Circle().fill(FreoPalette.surface)
                    .overlay(Circle().stroke(FreoPalette.primaryText, lineWidth: 1.5))
                    .overlay(Circle().fill(FreoPalette.accent).padding(4))
                    .frame(width: 16, height: 16).frame(width: 20)
                    .accessibilityHidden(true)
                Text("Robot position")
            }
        }
    }

    private func roomItem(_ title: String, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).stroke(FreoPalette.accent, lineWidth: width)
                .frame(width: 17, height: 12).frame(width: 20).accessibilityHidden(true)
            Text(title)
        }
    }

    private func item(_ title: String, dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(.clear)
                .frame(width: 20, height: 10)
                .overlay {
                    Path { path in path.move(to: CGPoint(x: 0, y: 5)); path.addLine(to: CGPoint(x: 20, y: 5)) }
                        .stroke(FreoPalette.primaryText, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: dash))
                }
                .accessibilityHidden(true)
            Text(title)
        }
    }
}

struct FloorRaster {
    struct Anchor {
        let roomID: Int
        let name: String
        let point: CGPoint
    }
    let image: CGImage
    let bounds: CGRect
    let anchors: [Anchor]
    let roomOutlines: [Int: Path]

    init?(floorplan: Floorplan, selected: Set<Int>, dark: Bool, highContrast: Bool,
          outlinedRoomIDs: Set<Int> = [], taskRoomIDs: Set<Int> = []) {
        let width = floorplan.width, height = floorplan.height
        guard width > 0, height > 0, width <= 1_000_000 / height,
              floorplan.pixels.count == width * height else { return nil }
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.accessibilityContrast = highContrast ? .high : .normal
        }
        func rgb(_ color: UIColor) -> [UInt8] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue].map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }
        }
        let background = rgb(.systemGroupedBackground)
        let wall = rgb(.opaqueSeparator)
        let floor = rgb(.secondarySystemGroupedBackground)
        // Related blue tones keep the map within the app's visual palette.
        // Opaque name badges keep text contrast independent of each room hue.
        let palette: [[UInt8]] = [
            [72, 119, 154], [91, 143, 173], [62, 103, 146], [107, 148, 175],
            [54, 133, 169], [93, 116, 161], [67, 145, 184], [105, 131, 159],
            [77, 103, 137], [90, 156, 188], [66, 126, 164], [118, 153, 182]
        ]
        let knownRoomIDs = Set(floorplan.rooms.map(\.id))
        let colorIndices = Dictionary(uniqueKeysWithValues: knownRoomIDs.sorted().enumerated().map { ($0.element, $0.offset) })
        func tint(_ color: [UInt8], amount: Double) -> [UInt8] {
            zip(color, background).map { UInt8((Double($0.0) * amount + Double($0.1) * (1 - amount)).rounded()) }
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        var centers: [Int: (x: Double, y: Double, count: Int)] = [:]
        for (index, value) in floorplan.pixels.enumerated() {
            let pixel = MapPixel(rawValue: value)
            let x = index % width, y = height - 1 - index / width
            var color = background
            if value != 0 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
                if pixel.flags == 40 || pixel.isUnreachable { color = wall }
                else if let room = pixel.knownRoomID(in: knownRoomIDs) {
                    var amount = selected.contains(room)
                        ? (dark && !highContrast ? 0.98 : 1.0)
                        : (highContrast ? (dark ? 0.96 : 1.0) : (dark ? 0.88 : 0.94))
                    if !selected.contains(room), !taskRoomIDs.contains(room),
                       !selected.isEmpty || !taskRoomIDs.isEmpty {
                        amount *= highContrast ? 0.82 : 0.68
                    }
                    color = tint(palette[(colorIndices[room] ?? 0) % palette.count], amount: amount)
                    let prior = centers[room] ?? (0, 0, 0)
                    centers[room] = (prior.x + Double(x) + 0.5, prior.y + Double(y) + 0.5, prior.count + 1)
                } else { color = floor }
            }
            let target = (y * width + x) * 4
            bytes[target] = color[0]; bytes[target + 1] = color[1]; bytes[target + 2] = color[2]
        }
        if maxX < 0 { minX = 0; minY = 0; maxX = width - 1; maxY = height - 1 }
        let left = max(0, minX - 3), top = max(0, minY - 3)
        let crop = CGRect(x: left, y: top, width: min(width, maxX + 4) - left, height: min(height, maxY + 4) - top)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let fullImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let image = fullImage.cropping(to: crop) else { return nil }
        var nearest: [Int: (distance: Double, point: CGPoint)] = [:]
        for (index, value) in floorplan.pixels.enumerated() {
            let pixel = MapPixel(rawValue: value)
            guard pixel.flags != 40, !pixel.isUnreachable,
                  let room = pixel.knownRoomID(in: knownRoomIDs),
                  let center = centers[room], center.count > 0 else { continue }
            let x = Double(index % width) + 0.5, y = Double(height - 1 - index / width) + 0.5
            let dx = x - center.x / Double(center.count), dy = y - center.y / Double(center.count)
            let distance = dx * dx + dy * dy
            if distance < (nearest[room]?.distance ?? .infinity) {
                nearest[room] = (distance, CGPoint(x: x, y: y))
            }
        }
        self.image = image
        bounds = crop
        var outlines: [Int: Path] = [:]
        func visibleRoom(x: Int, y: Int) -> Int? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let pixel = MapPixel(rawValue: floorplan.pixels[(height - 1 - y) * width + x])
            guard pixel.flags != 40, !pixel.isUnreachable else { return nil }
            return pixel.knownRoomID(in: knownRoomIDs)
        }
        func edge(_ roomID: Int, _ start: CGPoint, _ end: CGPoint) {
            outlines[roomID, default: Path()].move(to: start)
            outlines[roomID, default: Path()].addLine(to: end)
        }
        if !outlinedRoomIDs.isEmpty {
            for index in floorplan.pixels.indices {
                let x = index % width, y = height - 1 - index / width
                guard let roomID = visibleRoom(x: x, y: y), outlinedRoomIDs.contains(roomID) else { continue }
                if visibleRoom(x: x - 1, y: y) != roomID { edge(roomID, CGPoint(x: x, y: y), CGPoint(x: x, y: y + 1)) }
                if visibleRoom(x: x + 1, y: y) != roomID { edge(roomID, CGPoint(x: x + 1, y: y), CGPoint(x: x + 1, y: y + 1)) }
                if visibleRoom(x: x, y: y - 1) != roomID { edge(roomID, CGPoint(x: x, y: y), CGPoint(x: x + 1, y: y)) }
                if visibleRoom(x: x, y: y + 1) != roomID { edge(roomID, CGPoint(x: x, y: y + 1), CGPoint(x: x + 1, y: y + 1)) }
            }
        }
        roomOutlines = outlines
        anchors = floorplan.rooms.compactMap { room in
            guard let point = nearest[room.id]?.point else { return nil }
            return Anchor(roomID: room.id, name: room.name, point: point)
        }
    }
}

struct FloorLayout {
    struct RoomLabel {
        let roomID: Int
        let name: String
        let anchor: CGPoint
        let rect: CGRect
    }
    let bounds: CGRect
    let imageRect: CGRect
    let scale: CGFloat
    let labels: [RoomLabel]
    let rotated: Bool

    init(raster: FloorRaster, size: CGSize, rotated: Bool = false, robotRoomID: Int? = nil,
         selectedRoomIDs: Set<Int> = [], verticalInset: CGFloat = 18, reservedLabelArea: CGRect = .zero) {
        bounds = raster.bounds
        self.rotated = rotated
        let scale = max(0.001, min((size.width - 28) / raster.bounds.width, (size.height - 2 * verticalInset) / raster.bounds.height))
        self.scale = scale
        let frame = CGRect(x: (size.width - raster.bounds.width * scale) / 2,
                           y: (size.height - raster.bounds.height * scale) / 2,
                           width: raster.bounds.width * scale, height: raster.bounds.height * scale)
        imageRect = frame
        var placed: [RoomLabel] = []
        for room in raster.anchors.sorted(by: { $0.point.y < $1.point.y }) {
            let point = rotated
                ? CGPoint(x: raster.bounds.minX + raster.bounds.maxX - room.point.x,
                          y: raster.bounds.minY + raster.bounds.maxY - room.point.y)
                : room.point
            let anchor = CGPoint(x: frame.minX + (point.x - raster.bounds.minX) * scale,
                                 y: frame.minY + (point.y - raster.bounds.minY) * scale)
            // Measure the rendered font instead of estimating by character count: even
            // short labels could otherwise truncate, and custom names can wrap fully.
            let name = room.name
            let font = UIFont.systemFont(ofSize: 12, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let naturalWidth = (name as NSString).size(withAttributes: attributes).width
            let selectionWidth: CGFloat = selectedRoomIDs.contains(room.roomID) ? 18 : 0
            let width = min(max(64, naturalWidth + 20 + selectionWidth), max(64, min(170, size.width - 24)))
            let textBounds = (name as NSString).boundingRect(
                with: CGSize(width: width - 16 - selectionWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            let height = max(32, ceil(textBounds.height) + 16) + (room.roomID == robotRoomID ? 16 : 0)
            var offsets: [CGPoint] = []
            for ring in 0...12 {
                let x = CGFloat(ring) * 24, y = CGFloat(ring) * 31
                offsets.append(contentsOf: [CGPoint(x: 0, y: -y), CGPoint(x: 0, y: y), CGPoint(x: -x, y: 0),
                                           CGPoint(x: x, y: 0), CGPoint(x: -x, y: -y), CGPoint(x: x, y: -y),
                                           CGPoint(x: -x, y: y), CGPoint(x: x, y: y)])
            }
            offsets.sort { $0.x * $0.x + $0.y * $0.y < $1.x * $1.x + $1.y * $1.y }
            for offset in offsets {
                let rect = CGRect(x: max(6, min(size.width - width - 6, anchor.x + offset.x - width / 2)),
                                  y: max(8, min(size.height - height - 8, anchor.y + offset.y - height / 2)),
                                  width: width, height: height)
                if !rect.intersects(reservedLabelArea),
                   !placed.contains(where: { $0.rect.insetBy(dx: -3, dy: -3).intersects(rect) }) {
                    placed.append(RoomLabel(roomID: room.roomID, name: name, anchor: anchor, rect: rect))
                    break
                }
            }
        }
        labels = placed
    }

    func viewPoint(_ point: CGPoint) -> CGPoint {
        let point = rotated
            ? CGPoint(x: bounds.minX + bounds.maxX - point.x, y: bounds.minY + bounds.maxY - point.y)
            : point
        return CGPoint(x: imageRect.minX + (point.x - bounds.minX) * scale,
                       y: imageRect.minY + (point.y - bounds.minY) * scale)
    }

    func mapPoint(_ point: CGPoint) -> CGPoint {
        let point = CGPoint(x: (point.x - imageRect.minX) / scale + bounds.minX,
                            y: (point.y - imageRect.minY) / scale + bounds.minY)
        return rotated
            ? CGPoint(x: bounds.minX + bounds.maxX - point.x, y: bounds.minY + bounds.maxY - point.y)
            : point
    }

    func viewPath(_ path: Path) -> Path {
        let transform = rotated
            ? CGAffineTransform(a: -scale, b: 0, c: 0, d: -scale,
                                tx: imageRect.minX + bounds.maxX * scale,
                                ty: imageRect.minY + bounds.maxY * scale)
            : CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                tx: imageRect.minX - bounds.minX * scale,
                                ty: imageRect.minY - bounds.minY * scale)
        return path.applying(transform)
    }
}
