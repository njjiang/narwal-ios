import SwiftUI

struct RoomNamesView: View {
    var initialRoomIDs: Set<Int> = []
    @EnvironmentObject private var store: FreoStore
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: Floorplan?
    @State private var names: [Int: String] = [:]
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var needsReload = false
    @State private var error = ""
    @FocusState private var focusedRoom: Int?

    private var changes: Result<[Int: String], Error>? {
        baseline.map { map in Result { try RoomRenameTransaction.changedNames(in: map, requested: names) } }
    }
    private var validation: String? {
        if case .failure(let error)? = changes { return error.localizedDescription }
        return nil
    }
    private var canSave: Bool {
        guard case .success(let changed)? = changes else { return false }
        return !isLoading && !isSaving && !store.isBusy && !needsReload && !changed.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let baseline {
                    Section {
                        ForEach(baseline.rooms.filter { initialRoomIDs.isEmpty || initialRoomIDs.contains($0.id) }) { room in
                            TextField("Room name", text: Binding(
                                get: { names[room.id] ?? room.name },
                                set: { names[room.id] = $0; error = "" }
                            ))
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .focused($focusedRoom, equals: room.id)
                            .accessibilityLabel("Name for \(room.name)")
                            .disabled(isSaving || isLoading || needsReload)
                        }
                    }
                } else if isLoading {
                    Section { HStack(spacing: 12) { ProgressView(); Text("Loading rooms…") } }
                }
                if let validation, !needsReload {
                    Section { Text(validation).foregroundStyle(FreoPalette.secondaryText) }
                }
                if !error.isEmpty {
                    Section {
                        Text(error)
                        Button("Reload rooms") { Task { await load() } }
                            .disabled(isLoading || isSaving || store.isBusy)
                    }
                }
                if baseline != nil {
                    Section {
                        Button {
                            focusedRoom = nil
                            Task { await save() }
                        } label: {
                            HStack(spacing: 8) {
                                if isSaving { ProgressView() }
                                Text("Save names").fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(FreoPrimaryButtonStyle())
                        .disabled(!canSave)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(initialRoomIDs.count == 1 ? "Rename room" : "Rename rooms")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .tint(FreoPalette.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedRoom = nil }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .task {
                store.roomEditorPresented(true)
                if baseline == nil { await load() }
            }
            .onDisappear { store.roomEditorPresented(false) }
            .onChange(of: store.selectedDeviceID) { _, _ in invalidate() }
            .onChange(of: store.isDemo) { _, _ in invalidate() }
        }
    }

    private func load() async {
        isLoading = true; error = ""; needsReload = true
        defer { isLoading = false }
        do {
            let map = try await store.prepareRoomEditing()
            try Task.checkCancellation()
            guard initialRoomIDs.isSubset(of: Set(map.rooms.map(\.id))) else {
                throw ConnectorError.invalid("The selected rooms changed. Close this sheet and select them again on the map.")
            }
            baseline = map
            let selected = map.roomsWithArea.filter { initialRoomIDs.isEmpty || initialRoomIDs.contains($0.id) }
            names = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.name) })
            needsReload = false
            if selected.count == 1 { focusedRoom = selected.first?.id }
        } catch is CancellationError {
            // A dismissed load never creates a writable draft.
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard canSave, let baseline else { return }
        isSaving = true; error = ""
        defer { isSaving = false }
        do {
            try await store.saveRoomNames(names, baseline: baseline)
            dismiss()
        } catch {
            needsReload = true
            self.error = error.localizedDescription
        }
    }
    private func invalidate() {
        baseline = nil; names = [:]; needsReload = true
        error = "The selected robot changed. Reload its rooms."
    }
}
