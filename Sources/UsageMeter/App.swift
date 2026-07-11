import AppKit
import Combine

/// 純 menu bar app 進入點:NSStatusItem + NSPopover(取代 SwiftUI MenuBarExtra,降低常駐記憶體)。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var panel: PanelViewController!
    private var settingsWC: SettingsWindowController?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    // main.swift 頂層(nonisolated)要能建立本物件;@MainActor 物件改在啟動時才建。
    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 不顯示 Dock 圖示
        store = UsageStore()
        popover = NSPopover()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                              accessibilityDescription: "AI Usage")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }

        panel = PanelViewController(store: store, openSettings: { [weak self] in self?.openSettings() })
        // 只設 contentSize;不要改 window frame / view frame,否則會裁 header。
        panel.contentSizeDidChange = { [weak self] size in
            self?.popover.contentSize = size
        }
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: panelWidth, height: 280)
        popover.contentViewController = panel
        installPopoverDismissMonitors()

        // 選單列文字:用量或偏好(選單來源/語言)改變時更新。
        store.$results
            .sink { [weak self] _ in Task { @MainActor in self?.updateTitle() } }
            .store(in: &cancellables)
        Prefs.shared.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.updateTitle() } }
            .store(in: &cancellables)
        updateTitle()
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePopover()
    }

    private func updateTitle() {
        statusItem?.button?.title = " " + store.menuBarText
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            Task { await store.refreshIfStale(60) }   // 打開時資料過舊就重抓
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func installPopoverDismissMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.closePopoverIfEventIsOutside(event) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopoverIfEventIsOutside(_ event: NSEvent) {
        guard popover?.isShown == true else { return }
        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow { return }
        if let statusWindow = statusItem.button?.window,
           event.window === statusWindow { return }
        closePopover()
    }

    private func closePopover() {
        guard popover?.isShown == true else { return }
        popover.performClose(nil)
    }

    private func openSettings() {
        closePopover()
        if settingsWC == nil { settingsWC = SettingsWindowController(store: store) }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.center()
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
