import AppKit
import Combine

private let panelWidth: CGFloat = 300
private let listMaxHeight: CGFloat = 460

/// 點選單列 icon 後彈出的面板(取代 SwiftUI MenuView)。
@MainActor
final class PanelViewController: NSViewController {
    private let store: UsageStore
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let providerStack = NSStackView()
    private let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private let footerStack = NSStackView()

    private var lang: AppLanguage { Prefs.shared.language }

    init(store: UsageStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true

        // ── Header:標題 + 時間 + 右上角重新整理 ──
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        timeLabel.font = .systemFont(ofSize: 10)
        timeLabel.textColor = .secondaryLabelColor

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.isBordered = false
        refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = .labelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, headerSpacer, timeLabel, refreshButton, spinner])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        // ── 用量清單(可捲動)──
        providerStack.orientation = .vertical
        providerStack.alignment = .leading
        providerStack.spacing = 9
        providerStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(providerStack)
        NSLayoutConstraint.activate([
            providerStack.topAnchor.constraint(equalTo: doc.topAnchor),
            providerStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            providerStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            providerStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = doc
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: scrollView.widthAnchor).isActive = true
        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 60)
        scrollHeight.isActive = true

        // ── 分隔線 + 動作列 ──
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 1
        footerStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 6)
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scrollView)
        root.addSubview(sep)
        root.addSubview(footerStack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            sep.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            footerStack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let refresh: () -> Void = { [weak self] in Task { @MainActor in self?.rebuild() } }
        store.$results.sink { _ in refresh() }.store(in: &cancellables)
        store.$isRefreshing.sink { _ in refresh() }.store(in: &cancellables)
        store.$lastRefresh.sink { _ in refresh() }.store(in: &cancellables)
        Prefs.shared.objectWillChange.sink { _ in refresh() }.store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
    }

    @objc private func refreshTapped() { Task { await store.refreshAll() } }

    private func rebuild() {
        guard isViewLoaded else { return }
        titleLabel.stringValue = Loc.tr("app.title", lang)
        refreshButton.toolTip = Loc.tr("btn.refresh", lang)

        if let d = store.lastRefresh {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            timeLabel.stringValue = f.string(from: d)
        } else {
            timeLabel.stringValue = ""
        }
        if store.isRefreshing {
            refreshButton.isHidden = true; spinner.isHidden = false; spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil); spinner.isHidden = true; refreshButton.isHidden = false
        }

        // 重建各家用量列
        for v in providerStack.arrangedSubviews { providerStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for p in ProviderID.allCases {
            let usage = store.results[p] ?? .empty(p)
            let shown = usage.buckets.filter { Prefs.shared.isOn(p.rawValue, $0.key, buckets: usage.buckets) }
            // 全取消勾選且無錯誤就整家隱藏
            if shown.isEmpty && usage.error == nil && !usage.buckets.isEmpty { continue }
            let row = makeProviderRow(usage, shown: shown)
            providerStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: providerStack.widthAnchor).isActive = true
        }

        // 重建動作列
        for v in footerStack.arrangedSubviews { footerStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let prefsRow = MenuRowView(title: Loc.tr("btn.prefs", lang)) { [weak self] in self?.openSettings() }
        let quitRow = MenuRowView(title: Loc.tr("btn.quit", lang)) { NSApp.terminate(nil) }
        for r in [prefsRow, quitRow] {
            footerStack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: footerStack.widthAnchor).isActive = true
        }

        view.layoutSubtreeIfNeeded()
        scrollHeight.constant = min(max(providerStack.fittingSize.height, 1), listMaxHeight)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: panelWidth, height: view.fittingSize.height)
    }

    // MARK: - Row builders

    private func makeProviderRow(_ usage: ProviderUsage, shown: [UsageBucket]) -> NSView {
        let name = makeLabel(usage.provider.displayName, size: 13, weight: .semibold)
        let head = NSStackView(views: [name])
        head.orientation = .horizontal
        head.spacing = 6
        head.alignment = .centerY
        if let plan = usage.plan { head.addArrangedSubview(makeBadge(plan)) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        head.addArrangedSubview(spacer)
        if let e = usage.error { head.addArrangedSubview(makeLabel(e, size: 10, color: .systemOrange)) }

        let col = NSStackView(views: [head])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 5
        head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        if shown.isEmpty {
            col.addArrangedSubview(makeLabel(usage.error == nil ? Loc.tr("row.loading", lang) : "—",
                                             size: 11, color: .secondaryLabelColor))
        } else {
            for b in shown {
                let row = makeBarRow(b)
                col.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            }
        }
        return col
    }

    private func makeBarRow(_ b: UsageBucket) -> NSView {
        let name = makeLabel(Loc.tr(b.label, lang), size: 11)
        name.widthAnchor.constraint(equalToConstant: 74).isActive = true
        name.setContentCompressionResistancePriority(.required, for: .horizontal)

        let bar = BarView()
        bar.percent = b.usedPercent
        bar.fillColor = Self.barColor(b.usedPercent)
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pct = makeLabel("\(Int(b.usedPercent.rounded()))%", size: 11, mono: true)
        pct.alignment = .right
        pct.widthAnchor.constraint(equalToConstant: 36).isActive = true

        let reset = makeLabel(formatReset(b.resetsAt, lang: lang), size: 10, color: .secondaryLabelColor)
        reset.alignment = .right
        reset.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let h = NSStackView(views: [name, bar, pct, reset])
        h.orientation = .horizontal
        h.spacing = 8
        h.alignment = .centerY
        h.distribution = .fill
        return h
    }

    private func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
                           color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let tf = NSTextField(labelWithString: s)
        tf.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                       : .systemFont(ofSize: size, weight: weight)
        tf.textColor = color
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }

    private func makeBadge(_ s: String) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        box.layer?.cornerRadius = 4
        let tf = makeLabel(s, size: 10, color: .secondaryLabelColor)
        tf.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            tf.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            tf.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            tf.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.setContentCompressionResistancePriority(.required, for: .horizontal)
        return box
    }

    static func barColor(_ p: Double) -> NSColor {
        if p >= 90 { return .systemRed }
        if p >= 70 { return .systemOrange }
        return .systemGreen
    }
}

/// 用量進度條(layer 繪製,輕量)。
final class BarView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    var percent: Double = 0 { didSet { needsLayout = true } }
    var fillColor: NSColor = .systemGreen { didSet { fill.backgroundColor = fillColor.cgColor } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.backgroundColor = NSColor.gray.withAlphaComponent(0.22).cgColor
        track.cornerRadius = 3
        fill.cornerRadius = 3
        fill.backgroundColor = NSColor.systemGreen.cgColor
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 7) }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(percent / 100, 1)), height: bounds.height)
        CATransaction.commit()
    }
}

/// 全寬、滑過 highlight 的選單列(模擬原生 menu item)。
final class MenuRowView: NSView {
    private let titleLabel: NSTextField
    private let onClick: () -> Void

    init(title: String, onClick: @escaping () -> Void) {
        titleLabel = NSTextField(labelWithString: title)
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        titleLabel.textColor = .white
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        titleLabel.textColor = .labelColor
    }
    override func mouseUp(with event: NSEvent) { onClick() }
}
