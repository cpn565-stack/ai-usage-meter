import SwiftUI
import AppKit

struct UsageMeterApp: App {
    @StateObject private var store = UsageStore()
    @ObservedObject private var prefs = Prefs.shared

    init() {
        // 純 menu bar app:不顯示 Dock 圖示。
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Image(systemName: "gauge.with.dots.needle.50percent")
            Text(store.menuBarText)
        }
        .menuBarExtraStyle(.window)

        Window(Loc.tr("set.title", prefs.language), id: "settings") {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
