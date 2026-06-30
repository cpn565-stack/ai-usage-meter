import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    private var lang: AppLanguage { prefs.language }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 一般
                group(Loc.tr("set.general", lang)) {
                    labeledPicker(Loc.tr("set.language", lang), selection: $prefs.language) {
                        ForEach(AppLanguage.allCases) { l in
                            Text(l == .system ? Loc.tr("lang.system", lang) : l.nativeName).tag(l)
                        }
                    }
                    labeledPicker(Loc.tr("set.interval", lang), selection: $prefs.pollInterval) {
                        ForEach(PollInterval.allCases) { iv in Text(Loc.tr(iv.locKey, lang)).tag(iv) }
                    }
                    Toggle(Loc.tr("set.launch", lang), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { LoginItem.set($0) }
                }

                // 選單列顯示
                group(Loc.tr("set.menubar", lang)) {
                    labeledPicker(Loc.tr("set.menubar", lang), selection: $prefs.menuProvider) {
                        Text(Loc.tr("menu.all", lang)).tag("all")
                        ForEach(ProviderID.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .onChange(of: prefs.menuProvider) { _ in prefs.menuBucketKey = "" }

                    if let p = ProviderID(rawValue: prefs.menuProvider) {
                        labeledPicker(Loc.tr("menu.window", lang), selection: $prefs.menuBucketKey) {
                            Text(Loc.tr("bucket.max", lang)).tag("")
                            ForEach(store.enabledBuckets(p)) { b in
                                Text(Loc.tr(b.label, lang)).tag(b.key)
                            }
                        }
                    }
                }

                // 顯示細項(各家逐項勾選)
                group(Loc.tr("set.display", lang)) {
                    ForEach(ProviderID.allCases) { p in
                        let all = store.results[p]?.buckets ?? []
                        Text(p.displayName).font(.subheadline).fontWeight(.semibold)
                            .padding(.top, 2)
                        if all.isEmpty {
                            Text(Loc.tr("row.loading", lang)).font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(all) { b in
                                Toggle(Loc.tr(b.label, lang), isOn: Binding(
                                    get: { prefs.isOn(p.rawValue, b.key, buckets: all) },
                                    set: { prefs.toggle(p.rawValue, b.key, on: $0, buckets: all) }
                                ))
                                .toggleStyle(.checkbox).font(.callout)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 380, height: 560)
        .navigationTitle(Loc.tr("set.title", lang))
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func labeledPicker<S: Hashable, C: View>(_ title: String, selection: Binding<S>,
                                                     @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: selection) { content() }
                .labelsHidden().frame(maxWidth: 200)
        }
    }
}
