import SwiftUI

/// A single native toolbar item retains its position throughout a sync.
struct HistorySyncButton: View {
    let isLoading: Bool
    let isCancelling: Bool
    let isBusy: Bool
    let sync: () -> Void
    let cancel: () -> Void

    private var label: String {
        isCancelling ? "Stopping history sync" : isLoading ? "Cancel history sync" : "Sync history"
    }

    var body: some View {
        Button {
            if isLoading { cancel() } else { sync() }
        } label: {
            ZStack {
                if isLoading {
                    SyncActivityRing()
                    Image(systemName: "stop.fill")
                        .font(.system(size: 7, weight: .bold))
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
        }
        .disabled(isCancelling || (!isLoading && isBusy))
        .accessibilityLabel(label)
        .accessibilityValue(isLoading ? "Syncing" : "")
        .accessibilityHint(isLoading ? "Stops downloading. Saved paths are kept." : "Downloads available cleaning history.")
        .accessibilityIdentifier(isLoading ? "cancelHistorySync" : "syncHistory")
    }
}

private struct SyncActivityRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .stroke(FreoPalette.accent.opacity(0.18), lineWidth: 1.8)
            .overlay {
                Circle().trim(from: 0, to: 0.7)
                    .stroke(FreoPalette.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
            }
            .frame(width: 22, height: 22)
            .task(id: reduceMotion) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { rotation = 0 }
                if !reduceMotion {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            }
    }
}
