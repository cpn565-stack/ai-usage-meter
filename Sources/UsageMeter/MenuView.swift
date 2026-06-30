import SwiftUI

struct MenuView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.openWindow) private var openWindow

    private var lang: AppLanguage { prefs.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 標題 + 右上角重新整理 icon
            HStack(spacing: 6) {
                Text(Loc.tr("app.title", lang)).font(.headline)
                Spacer()
                if let d = store.lastRefresh {
                    Text(timeString(d)).font(.caption2).foregroundStyle(.secondary)
                }
                if store.isRefreshing {
                    ProgressView().scaleEffect(0.5).frame(width: 18, height: 18)
                } else {
                    Button { Task { await store.refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help(Loc.tr("btn.refresh", lang))
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            // 各家用量(只顯示勾選的細項;太長則可捲動)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(ProviderID.allCases) { p in
                        let usage = store.results[p] ?? .empty(p)
                        let shown = usage.buckets.filter {
                            prefs.isOn(p.rawValue, $0.key, buckets: usage.buckets)
                        }
                        // 全被取消勾選且無錯誤就整家隱藏
                        if !(shown.isEmpty && usage.error == nil && !usage.buckets.isEmpty) {
                            ProviderRow(usage: usage, shown: shown, lang: lang)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: 460)

            Divider().padding(.vertical, 8)

            // 下方動作列(選單樣式)
            VStack(spacing: 1) {
                MenuRow(title: Loc.tr("btn.prefs", lang)) {
                    openWindow(id: "settings")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                MenuRow(title: Loc.tr("btn.quit", lang)) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(width: 300)
        .onAppear { Task { await store.refreshIfStale(60) } }   // 打開選單時若資料過舊就重抓
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// 全寬、滑過 highlight 的選單列(模擬原生 menu item)。
struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(hover ? Color.accentColor.opacity(0.85) : Color.clear)
        .foregroundStyle(hover ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover { hover = $0 }
    }
}

struct ProviderRow: View {
    let usage: ProviderUsage
    let shown: [UsageBucket]
    let lang: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(usage.provider.displayName).fontWeight(.semibold)
                if let plan = usage.plan {
                    Text(plan).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
                }
                Spacer()
                if let e = usage.error { Text(e).font(.caption2).foregroundStyle(.orange) }
            }
            if shown.isEmpty {
                Text(usage.error == nil ? Loc.tr("row.loading", lang) : "—")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(shown) { UsageBar(bucket: $0, lang: lang) }
            }
        }
    }
}

struct UsageBar: View {
    let bucket: UsageBucket
    let lang: AppLanguage

    var body: some View {
        HStack(spacing: 8) {
            Text(Loc.tr(bucket.label, lang)).font(.caption).frame(width: 74, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.22))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(bucket.usedPercent / 100, 1)))
                }
            }
            .frame(height: 7)
            Text("\(Int(bucket.usedPercent.rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
            Text(formatReset(bucket.resetsAt, lang: lang)).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var color: Color {
        let p = bucket.usedPercent
        if p >= 90 { return .red }
        if p >= 70 { return .orange }
        return .green
    }
}
