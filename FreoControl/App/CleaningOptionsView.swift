import SwiftUI

@MainActor
struct CleaningOptionsView: View {
    @EnvironmentObject private var store: FreoStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Mode", value: store.mode.title)
                        .cleaningOptionsRow()
                    Stepper(value: $store.cleaningOptions.passes, in: 1...2) {
                        LabeledContent(store.mode == .vacuumThenMop ? "Passes per stage" : "Passes",
                                       value: String(store.cleaningOptions.passes))
                    }
                    .cleaningOptionsRow()
                    if store.mode != .mop {
                        Picker("Suction", selection: $store.cleaningOptions.suction) {
                            ForEach(CleaningSuction.allCases) { Text($0.title).tag($0) }
                        }
                        .cleaningOptionsRow()
                    }
                    if store.mode != .vacuum {
                        Picker("Mop moisture", selection: $store.cleaningOptions.humidity) {
                            ForEach(CleaningHumidity.allCases) { Text($0.title).tag($0) }
                        }
                        .cleaningOptionsRow()
                    }
                    Picker("Route", selection: $store.cleaningOptions.route) {
                        ForEach(CleaningRoute.allCases) { Text($0.title).tag($0) }
                    }
                    .cleaningOptionsRow()
                } footer: {
                    Text("Applies to all selected rooms on the next Start.")
                }
                .disabled(store.isBusy)

                Section {
                    Button("Reset to standard") { store.cleaningOptions = .standard }
                        .disabled(store.isBusy || store.cleaningOptions == .standard)
                        .cleaningOptionsRow()
                }
            }
            .environment(\.defaultMinListRowHeight, 44)
            .navigationTitle("Cleaning options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    func cleaningOptionsRow() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
