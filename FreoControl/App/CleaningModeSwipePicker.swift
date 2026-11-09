import SwiftUI

struct CleaningModeSwipePicker: View {
    @Binding var mode: CleaningMode
    var isBusy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false
    @State private var dragOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 1
    @State private var dragIntent: DragIntent = .undecided
    @State private var dragStartMode: CleaningMode?
    @State private var gestureCancelled = false

    private enum DragIntent { case undecided, horizontal, vertical }
    private let modes: [CleaningMode] = [.vacuumMop, .vacuum, .mop, .vacuumThenMop]
    private var selectedIndex: Int { modes.firstIndex(of: mode) ?? 0 }
    private var settlingAnimation: Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.52, dampingFraction: 0.94)
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                modeArrow("chevron.left", step: -1)
                modePages
                modeArrow("chevron.right", step: 1)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cleaning mode")
            .accessibilityValue(mode.title)
            .accessibilityHint("Swipe up or down to change the mode.")
            .accessibilityAdjustableAction { direction in
                guard !isBusy else { return }
                switch direction {
                case .increment: settle(by: 1)
                case .decrement: settle(by: -1)
                @unknown default: break
                }
            }
            modeChoices
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(modeDrag)
        .disabled(isBusy)
        .sensoryFeedback(.selection, trigger: mode)
        .onChange(of: isDragging) { _, dragging in
            // Also handles an interrupted gesture, for which onEnded is not called.
            if !dragging {
                settle(by: 0)
                dragStartMode = nil
                gestureCancelled = false
            }
        }
        .onChange(of: isBusy) { _, busy in
            if busy {
                if isDragging { gestureCancelled = true }
                settle(by: 0)
            }
        }
        .onChange(of: mode) { _, _ in
            // Siri/demo may update the binding while a finger is still down.
            if isDragging, let dragStartMode, dragStartMode != mode {
                gestureCancelled = true
                settle(by: 0)
            }
        }
    }

    private var modePages: some View {
        // Reserve the tallest label at the actual available width. The pager
        // never changes the footer's height while moving between modes.
        ZStack {
            ForEach(modes) { item in modeLabel(item).hidden() }
        }
        .frame(maxWidth: .infinity)
        .overlay {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                HStack(spacing: 0) {
                    ForEach(modes) { item in
                        modeLabel(item)
                            .frame(width: width, height: proxy.size.height)
                    }
                }
                .offset(x: -CGFloat(selectedIndex) * width + dragOffset)
                .onAppear { pageWidth = width }
                .onChange(of: width) { _, value in
                    pageWidth = value
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { dragOffset = 0; dragIntent = .undecided }
                }
            }
            .clipped()
        }
    }

    private func modeLabel(_ item: CleaningMode) -> some View {
        Text(item == .vacuumThenMop ? "Vacuum → Mop" : item.title)
            .font(.headline)
            .foregroundStyle(FreoPalette.primaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    private var modeChoices: some View {
        HStack(spacing: 2) {
            ForEach(modes) { item in
                Button { settle(by: (modes.firstIndex(of: item) ?? 0) - selectedIndex) } label: {
                    modeSymbol(item)
                        .foregroundStyle(mode == item ? FreoPalette.onAccent : FreoPalette.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if mode == item {
                                Capsule().fill(FreoPalette.buttonFill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(mode == item ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func modeSymbol(_ item: CleaningMode) -> some View {
        HStack(spacing: 2) {
            if item != .mop {
                Image(systemName: "wind")
            }
            if item == .vacuumMop || item == .vacuumThenMop {
                Image(systemName: item == .vacuumMop ? "plus" : "arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            if item != .vacuum {
                Image(systemName: "drop.fill")
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .accessibilityHidden(true)
    }

    private var modeDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { value in
                guard !isBusy, !gestureCancelled else { return }
                if dragStartMode == nil { dragStartMode = mode }
                guard dragStartMode == mode else { gestureCancelled = true; return }
                let dx = value.translation.width, dy = value.translation.height
                if dragIntent == .undecided {
                    dragIntent = abs(dx) > abs(dy) * 1.2 ? .horizontal : .vertical
                }
                guard dragIntent == .horizontal, !reduceMotion else { return }
                let atEdge = (selectedIndex == 0 && dx > 0) ||
                    (selectedIndex == modes.count - 1 && dx < 0)
                let distance = min(abs(dx), pageWidth)
                let offset = (dx < 0 ? -distance : distance) * (atEdge ? 0.2 : 1)
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { dragOffset = offset }
            }
            .onEnded { value in
                let dx = value.translation.width
                // Require a deliberate distance; a tiny fast flick should not
                // jump to another cleaning mode just because of its velocity.
                let commitDistance = min(88, max(56, pageWidth * 0.32))
                let commits = abs(dx) >= commitDistance
                let step = !isBusy && !gestureCancelled && dragStartMode == mode &&
                    dragIntent == .horizontal && commits ? (dx < 0 ? 1 : -1) : 0
                dragStartMode = nil
                settle(by: step)
            }
    }

    private func modeArrow(_ symbol: String, step: Int) -> some View {
        let enabled = modes.indices.contains(selectedIndex + step)
        return Button { settle(by: step) } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FreoPalette.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.25)
    }

    private func settle(by offset: Int) {
        let next = min(modes.count - 1, max(0, selectedIndex + (isBusy ? 0 : offset)))
        // Binding and translation settle together, continuing from the finger's
        // position rather than replacing the label at the end of the gesture.
        withAnimation(settlingAnimation) {
            mode = modes[next]
            dragOffset = 0
            dragIntent = .undecided
        }
    }
}
