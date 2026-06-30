import AppKit
import Combine

/// 偏好設定視窗(取代 SwiftUI SettingsView)。語言/用量改變時整體重建以重新本地化。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: UsageStore
    private var cancellables = Set<AnyCancellable>()
    private let contentStack = NSStackView()
    private var rebuilding = false

    private var lang: AppLanguage { Prefs.shared.language }

    init(store: UsageStore) {
        self.store = store
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        win.title = Loc.tr("set.title", lang)
        setupScroll()
        rebuild()

        let refresh: () -> Void = { [weak self] in Task { @MainActor in self?.rebuild() } }
        store.$results.sink { _ in refresh() }.store(in: &cancellables)
        Prefs.shared.objectWillChange.sink { _ in refresh() }.store(in: &cancellables)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupScroll() {
        guard let win = window else { return }
        let scroll = NSScrollView(frame: win.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20),
        ])
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        win.contentView!.addSubview(scroll)
    }

    private func rebuild() {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }

        window?.title = Loc.tr("set.title", lang)
        for v in contentStack.arrangedSubviews { contentStack.removeArrangedSubview(v); v.removeFromSuperview() }

        // ── 一般 ──
        let langPopup = popup(AppLanguage.allCases.map { $0 == .system ? Loc.tr("lang.system", lang) : $0.nativeName },
                              selected: AppLanguage.allCases.firstIndex(of: Prefs.shared.language) ?? 0,
                              action: #selector(languageChanged))
        let intervalPopup = popup(PollInterval.allCases.map { Loc.tr($0.locKey, lang) },
                                  selected: PollInterval.allCases.firstIndex(of: Prefs.shared.pollInterval) ?? 0,
                                  action: #selector(intervalChanged))
        let launch = NSButton(checkboxWithTitle: Loc.tr("set.launch", lang), target: self, action: #selector(launchToggled))
        launch.state = LoginItem.isEnabled ? .on : .off
        let providerChecks = ProviderID.allCases.map { p in
            let cb = NSButton(checkboxWithTitle: p.displayName, target: self, action: #selector(providerToggled))
            cb.state = Prefs.shared.isProviderEnabled(p) ? .on : .off
            cb.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
            return cb
        }
        addSection(Loc.tr("set.general", lang), rows: [
            labeledRow(Loc.tr("set.language", lang), langPopup),
            labeledRow(Loc.tr("set.interval", lang), intervalPopup),
            launch,
            labeledRow(Loc.tr("set.version", lang), makeLabel(appVersion(), size: 13, color: .secondaryLabelColor)),
        ])
        addSection(Loc.tr("set.providers", lang), rows: providerChecks)

        // ── 選單列顯示 ──
        let providers = ProviderID.allCases.filter { Prefs.shared.isProviderEnabled($0) }
        let provOpts = ["all"] + providers.map { $0.rawValue }
        let provTitles = [Loc.tr("menu.all", lang)] + providers.map { $0.displayName }
        let provPopup = popup(provTitles,
                              selected: provOpts.firstIndex(of: Prefs.shared.menuProvider) ?? 0,
                              action: #selector(menuProviderChanged))
        var menubarRows: [NSView] = [labeledRow(Loc.tr("set.menubar", lang), provPopup)]
        if let p = ProviderID(rawValue: Prefs.shared.menuProvider) {
            let keys = [""] + store.enabledBuckets(p).map { $0.key }
            let titles = [Loc.tr("bucket.max", lang)] + store.enabledBuckets(p).map { Loc.tr($0.label, lang) }
            let bucketPopup = popup(titles,
                                    selected: keys.firstIndex(of: Prefs.shared.menuBucketKey) ?? 0,
                                    action: #selector(menuBucketChanged))
            menubarRows.append(labeledRow(Loc.tr("menu.window", lang), bucketPopup))
        }
        addSection(Loc.tr("set.menubar", lang), rows: menubarRows)

        // ── 顯示細項(各家逐項勾選)──
        var displayRows: [NSView] = []
        for p in ProviderID.allCases {
            let all = store.results[p]?.buckets ?? []
            displayRows.append(makeLabel(p.displayName, size: 12, weight: .semibold))
            if !Prefs.shared.isProviderEnabled(p) {
                displayRows.append(makeLabel(Loc.tr("row.disabled", lang), size: 11, color: .secondaryLabelColor))
            } else if all.isEmpty {
                displayRows.append(makeLabel(Loc.tr("row.loading", lang), size: 11, color: .secondaryLabelColor))
            } else {
                for b in all {
                    let cb = NSButton(checkboxWithTitle: Loc.tr(b.label, lang), target: self, action: #selector(bucketToggled))
                    cb.state = Prefs.shared.isOn(p.rawValue, b.key, buckets: all) ? .on : .off
                    cb.identifier = NSUserInterfaceItemIdentifier("\(p.rawValue)|\(b.key)")
                    displayRows.append(cb)
                }
            }
        }
        addSection(Loc.tr("set.display", lang), rows: displayRows)
    }

    // MARK: - Section / row helpers

    private func addSection(_ title: String, rows: [NSView]) {
        let header = makeLabel(title, size: 13, weight: .semibold)
        let section = NSStackView(views: [header] + rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        for r in rows where r is NSStackView {
            r.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let l = makeLabel(title, size: 13)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let h = NSStackView(views: [l, spacer, control])
        h.orientation = .horizontal
        h.spacing = 8
        h.alignment = .centerY
        control.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return h
    }

    private func popup(_ titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.addItems(withTitles: titles)
        if selected >= 0 && selected < titles.count { b.selectItem(at: selected) }
        b.target = self
        b.action = action
        return b
    }

    private func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
                           color: NSColor = .labelColor) -> NSTextField {
        let tf = NSTextField(labelWithString: s)
        tf.font = .systemFont(ofSize: size, weight: weight)
        tf.textColor = color
        return tf
    }

    private func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    // MARK: - Actions

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        Prefs.shared.language = AppLanguage.allCases[sender.indexOfSelectedItem]
    }
    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        Prefs.shared.pollInterval = PollInterval.allCases[sender.indexOfSelectedItem]
    }
    @objc private func launchToggled(_ sender: NSButton) {
        LoginItem.set(sender.state == .on)
    }
    @objc private func providerToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let p = ProviderID(rawValue: raw) else { return }
        Prefs.shared.setProvider(p, enabled: sender.state == .on)
        if sender.state == .on {
            Task { await store.refresh(p) }
        }
    }
    @objc private func menuProviderChanged(_ sender: NSPopUpButton) {
        let opts = ["all"] + ProviderID.allCases.filter { Prefs.shared.isProviderEnabled($0) }.map { $0.rawValue }
        Prefs.shared.menuProvider = opts[sender.indexOfSelectedItem]
        Prefs.shared.menuBucketKey = ""
    }
    @objc private func menuBucketChanged(_ sender: NSPopUpButton) {
        guard let p = ProviderID(rawValue: Prefs.shared.menuProvider) else { return }
        let keys = [""] + store.enabledBuckets(p).map { $0.key }
        guard sender.indexOfSelectedItem < keys.count else { return }
        Prefs.shared.menuBucketKey = keys[sender.indexOfSelectedItem]
    }
    @objc private func bucketToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let p = ProviderID(rawValue: parts[0]) else { return }
        let all = store.results[p]?.buckets ?? []
        Prefs.shared.toggle(p.rawValue, parts[1], on: sender.state == .on, buckets: all)
    }
}
