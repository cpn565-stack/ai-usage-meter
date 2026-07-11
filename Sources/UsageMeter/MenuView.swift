import AppKit
import Combine

let panelWidth: CGFloat = 320
private let listMaxHeight: CGFloat = 460

/// 點選單列 icon 後彈出的面板(取代 SwiftUI MenuView)。
@MainActor
final class PanelViewController: NSViewController {
    private let store: UsageStore
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let headerStack = NSStackView()
    private let providerStack = NSStackView()
    private let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private let footerStack = NSStackView()
    var contentSizeDidChange: ((NSSize) -> Void)?

    private var lang: AppLanguage { Prefs.shared.language }

    init(store: UsageStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        // 寬度用約束鎖死,高度由子視圖 + scrollHeight 推算。
        root.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = root.widthAnchor.constraint(equalToConstant: panelWidth)
        widthConstraint.priority = .required
        widthConstraint.isActive = true

        // ── Header:標題 + 時間 + 右上角重新整理 ──
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .systemFont(ofSize: 10)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.isBordered = false
        refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = .labelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        let titleCol = NSStackView(views: [titleLabel, statusLabel])
        titleCol.orientation = .vertical
        titleCol.spacing = 1
        titleCol.alignment = .leading
        titleCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY
        headerStack.distribution = .fill
        headerStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setHuggingPriority(.required, for: .vertical)
        headerStack.setContentCompressionResistancePriority(.required, for: .vertical)
        for v in [titleCol as NSView, headerSpacer, timeLabel, refreshButton, spinner] {
            headerStack.addArrangedSubview(v)
        }

        // ── 用量清單(可捲動)──
        providerStack.orientation = .vertical
        providerStack.alignment = .leading
        providerStack.spacing = 9
        providerStack.distribution = .fill
        providerStack.translatesAutoresizingMaskIntoConstraints = false
        // 避免被 scrollView 舊高度撐開,否則取消細項後 fittingSize 仍回報過高。
        providerStack.setHuggingPriority(.required, for: .vertical)
        providerStack.setContentCompressionResistancePriority(.required, for: .vertical)

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
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = doc
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
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
        footerStack.setHuggingPriority(.required, for: .vertical)
        footerStack.setContentCompressionResistancePriority(.required, for: .vertical)

        root.addSubview(headerStack)
        root.addSubview(scrollView)
        root.addSubview(sep)
        root.addSubview(footerStack)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: root.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            sep.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            sep.heightAnchor.constraint(equalToConstant: 1),

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
        store.$lastSuccessfulRefresh.sink { _ in refresh() }.store(in: &cancellables)
        Prefs.shared.objectWillChange.sink { _ in refresh() }.store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
    }

    @objc private func refreshTapped() { Task { await store.refreshAll() } }

    /// Self-test:載入 view、rebuild,回傳關鍵布局量測。
    func probeLayoutForTest() -> PanelLayoutProbe {
        _ = view
        rebuild()
        view.layoutSubtreeIfNeeded()
        let refreshFrame = refreshButton.convert(refreshButton.bounds, to: view)
        let headerFrame = headerStack.convert(headerStack.bounds, to: view)
        var rightmost: CGFloat = 0
        func walk(_ v: NSView) {
            let f = v.convert(v.bounds, to: self.view)
            rightmost = max(rightmost, f.maxX)
            for c in v.subviews { walk(c) }
        }
        walk(view)
        return PanelLayoutProbe(
            contentSize: preferredContentSize,
            headerHeight: headerFrame.height,
            headerMinY: headerFrame.minY,
            refreshVisible: !refreshButton.isHidden,
            refreshMaxX: refreshFrame.maxX,
            refreshMinY: refreshFrame.minY,
            rightmostContentX: rightmost,
            panelWidth: panelWidth
        )
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        titleLabel.stringValue = Loc.tr("app.title", lang)
        refreshButton.toolTip = Loc.tr("btn.refresh", lang)
        statusLabel.stringValue = statusText()
        statusLabel.toolTip = statusLabel.stringValue

        if let d = store.lastRefresh {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            timeLabel.stringValue = f.string(from: d)
        } else {
            timeLabel.stringValue = ""
        }
        if store.activeErrorCount > 0 {
            timeLabel.stringValue = "\(store.activeErrorCount)!"
            timeLabel.textColor = .systemOrange
        } else {
            timeLabel.textColor = .secondaryLabelColor
        }
        if store.isRefreshing {
            refreshButton.isHidden = true; spinner.isHidden = false; spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil); spinner.isHidden = true; refreshButton.isHidden = false
        }

        // 重建各家用量列
        for v in providerStack.arrangedSubviews { providerStack.removeArrangedSubview(v); v.removeFromSuperview() }
        var rowCount = 0
        for p in ProviderID.allCases where Prefs.shared.isProviderEnabled(p) {
            let usage = store.results[p] ?? .empty(p)
            let shown = usage.buckets.filter { Prefs.shared.isOn(p.rawValue, $0.key, buckets: usage.buckets) }
            // 全取消勾選且無錯誤就整家隱藏
            if shown.isEmpty && usage.error == nil && !usage.buckets.isEmpty { continue }
            let row = makeProviderRow(usage, shown: shown)
            providerStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: providerStack.widthAnchor).isActive = true
            rowCount += 1
        }
        if rowCount == 0 {
            let empty = makeLabel(Loc.tr("row.noProviders", lang), size: 11, color: .secondaryLabelColor)
            providerStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: providerStack.widthAnchor).isActive = true
        }

        // 重建動作列
        for v in footerStack.arrangedSubviews { footerStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let prefsRow = MenuRowView(title: Loc.tr("btn.prefs", lang)) { [weak self] in self?.openSettings() }
        let quitRow = MenuRowView(title: Loc.tr("btn.quit", lang)) { NSApp.terminate(nil) }
        for r in [prefsRow, quitRow] {
            footerStack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: footerStack.widthAnchor).isActive = true
        }

        updateContentSize()
    }

    private func updateContentSize() {
        // 先把 scroll 區收成 1pt 再量,避免 providerStack 被上一輪的大高度撐開。
        scrollHeight.constant = 1
        view.layoutSubtreeIfNeeded()

        let contentH = measuredProviderStackHeight()
        scrollHeight.constant = min(max(contentH, 1), listMaxHeight)
        view.layoutSubtreeIfNeeded()

        headerStack.layoutSubtreeIfNeeded()
        footerStack.layoutSubtreeIfNeeded()
        let headerH = max(headerStack.fittingSize.height, 40)
        let footerH = max(footerStack.fittingSize.height, 54)
        let sepAndGaps: CGFloat = 8 + 1 + 8
        let totalH = ceil(headerH + scrollHeight.constant + sepAndGaps + footerH)

        let size = NSSize(width: panelWidth, height: max(totalH, 120))
        preferredContentSize = size
        contentSizeDidChange?(size)
    }

    /// 直接加總 arranged subviews 高度 + spacing,不依賴可能被父視圖撐開的 fittingSize。
    private func measuredProviderStackHeight() -> CGFloat {
        let views = providerStack.arrangedSubviews
        guard !views.isEmpty else { return 1 }
        var height: CGFloat = 0
        for (i, v) in views.enumerated() {
            v.layoutSubtreeIfNeeded()
            let fitted = v.fittingSize.height
            let intrinsic = v.intrinsicContentSize.height
            let rowH = max(fitted, intrinsic, v.frame.height, 1)
            height += rowH
            if i > 0 { height += providerStack.spacing }
        }
        return ceil(height)
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

        let col = NSStackView(views: [head])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 5
        col.distribution = .fill
        col.setHuggingPriority(.required, for: .vertical)
        col.setContentCompressionResistancePriority(.required, for: .vertical)
        head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        if let e = usage.error {
            let err = makeLabel(e, size: 10, color: .systemOrange)
            err.toolTip = e
            err.maximumNumberOfLines = 2
            err.lineBreakMode = .byWordWrapping
            col.addArrangedSubview(err)
            err.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }

        if shown.isEmpty {
            if usage.error == nil {
                col.addArrangedSubview(makeLabel(Loc.tr("row.loading", lang), size: 11, color: .secondaryLabelColor))
            }
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
        bar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pct = makeLabel("\(Int(b.usedPercent.rounded()))%", size: 11, mono: true)
        pct.alignment = .right
        pct.widthAnchor.constraint(equalToConstant: 36).isActive = true
        pct.setContentCompressionResistancePriority(.required, for: .horizontal)
        pct.setContentHuggingPriority(.required, for: .horizontal)

        let reset = makeLabel(formatReset(b.resetsAt, lang: lang), size: 10, color: .secondaryLabelColor)
        reset.alignment = .right
        // 夠放「↻6d7h」;優先壓縮 bar 而不是裁切 reset。
        reset.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        reset.widthAnchor.constraint(lessThanOrEqualToConstant: 64).isActive = true
        reset.setContentCompressionResistancePriority(.required, for: .horizontal)
        reset.setContentHuggingPriority(.required, for: .horizontal)

        let h = NSStackView(views: [name, bar, pct, reset])
        h.orientation = .horizontal
        h.spacing = 6
        h.alignment = .centerY
        h.distribution = .fill
        h.setHuggingPriority(.required, for: .vertical)
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

    private func statusText() -> String {
        if store.isRefreshing { return Loc.tr("status.refreshing", lang) }
        let enabledCount = ProviderID.allCases.filter { Prefs.shared.isProviderEnabled($0) }.count
        if enabledCount == 0 { return Loc.tr("status.noProviders", lang) }
        if store.activeErrorCount > 0 {
            return String(format: Loc.tr("status.errors", lang), store.activeErrorCount)
        }
        guard let last = store.lastSuccessfulRefresh ?? store.lastRefresh else {
            return Loc.tr("foot.never", lang)
        }
        let updated = String(format: Loc.tr("status.updated", lang), shortTime(last))
        if let next = store.nextRefresh {
            return updated + " · " + String(format: Loc.tr("status.next", lang), shortTime(next))
        }
        return updated + " · " + Loc.tr("interval.manual", lang)
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
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
