import SwiftUI
import AppIntents
import UIKit

@main
@MainActor
struct FreoControlApp: App {
    @StateObject private var store = FreoStore.shared
    @Environment(\.scenePhase) private var scenePhase
    private let diagnosticMode: Bool
    private let opensFloorplan: Bool

    init() {
        FreoSiriTrace.record("app launched", detail: "Narwal")
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        #if FREO_SIRI_ROUTING_TESTS
        FreoSiriRoutingTestMode.configure(arguments: arguments)
        UIApplication.shared.isIdleTimerDisabled = FreoSiriRoutingTestMode.isActive
        #endif
        opensFloorplan = arguments.contains("--freo-show-floorplan")
        diagnosticMode = arguments.contains("--freo-diagnostic-request")
        if diagnosticMode { Task { await FreoDiagnosticRunner.runOnce(arguments: arguments) } }
        #else
        diagnosticMode = false
        opensFloorplan = false
        #endif
        if !diagnosticMode {
            FreoShortcuts.updateAppShortcutParameters()
            Task { @MainActor in
                FreoSiriRoomIndex.refresh((try? await FreoStore.shared.siriRoomSuggestions()) ?? [])
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if diagnosticMode {
                Text("Saving room changes…")
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            } else {
                ContentView()
                .environmentObject(store)
                .overlay(alignment: .top) {
                    #if DEBUG && FREO_SIRI_ROUTING_TESTS
                    if FreoSiriRoutingTestMode.isActive {
                        VStack {
                            Text("Siri routing test — Siri starts do not run the robot")
                                .accessibilityIdentifier("siriRoutingTestMode")
                            Text(store.message).accessibilityIdentifier("siriRoutingTestResult")
                        }
                        .font(.caption).padding(8)
                        .background(.regularMaterial)
                    }
                    #endif
                }
                .fontDesign(.default)
                .tint(FreoPalette.accent)
                .onAppear { store.foregroundChanged(true) }
                .task {
                    await store.restoreSavedSessionIfNeeded()
                    if opensFloorplan {
                        store.selectedTab = 1
                        await store.loadFloorplan()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    store.foregroundChanged(phase == .active)
                    if phase == .active { Task { await store.restoreSavedSessionIfNeeded(retry: true) } }
                }
            }
        }
    }
}
