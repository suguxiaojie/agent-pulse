import SwiftUI

private enum GlanceSettingsSection: String, CaseIterable, Identifiable {
    case content = "内容"
    case appearance = "外观"

    var id: String { rawValue }
}

struct GlanceContentSettingsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var claude: ClaudeCodeRuntime
    @ObservedObject private var grok: GrokRuntime
    @ObservedObject private var antigravity: AntigravityRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("glance.provider") private var savedProvider = "codex"
    @AppStorage(GlanceContentPreferenceKey.showPrimaryQuota) private var showPrimaryQuota = true
    @AppStorage(GlanceContentPreferenceKey.showCostEstimate) private var showCostEstimate = true
    @AppStorage(GlanceContentPreferenceKey.showCreditBalance) private var showCreditBalance = true
    @AppStorage(GlanceContentPreferenceKey.showDailyTokens) private var showDailyTokens = true
    @AppStorage(GlanceContentPreferenceKey.showThirtyDayTokens) private var showThirtyDayTokens = true
    @AppStorage(GlanceContentPreferenceKey.showTokenActivity) private var showTokenActivity = true
    @AppStorage(GlanceContentPreferenceKey.showResetEntry) private var showResetEntry = true
    @AppStorage(GlanceContentPreferenceKey.surfaceOpacity) private var surfaceOpacity = 0.38
    @State private var countStyle = CountStyle.load()
    @State private var isAdjustingOpacity = false
    @State private var selectedSection = GlanceSettingsSection.content
    @State private var confirmingReset = false

    init(store: MonitorStore) {
        self.store = store
        self.claude = store.claude
        self.grok = store.grok
        self.antigravity = store.antigravity
    }

    private var previewCaption: String {
        switch resolvedProvider {
        case .codex: return "当前 Codex 账号实时数据"
        case .claude: return "本机 Claude Code 实时数据"
        case .grok: return "Grok 官方额度与本机实时数据"
        case .antigravity: return "Antigravity 三端实时数据"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            SettingsWorkbench(isAdjusting: isAdjustingOpacity) {
                SettingsStage(title: "实时面板", status: "只读预览", caption: previewCaption) {
                    GlanceSettingsPreview(store: store, preferences: preferences)
                }.modifier(MonitorDesktopReveal(delay: 0))
            } controls: {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        PanelSettingsSegments(options: GlanceSettingsSection.allCases.map(\.rawValue), selection: Binding(
                            get: { selectedSection.rawValue },
                            set: { if let section = GlanceSettingsSection(rawValue: $0) { selectedSection = section } }
                        ))
                        Spacer(minLength: 8)
                        Text("\(visibleContentCount) / 7 项显示")
                            .font(MonitorDesktopTypography.valueBadge)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(MonitorDesktopTheme.primaryText.opacity(0.05), in: Capsule())
                            .fixedSize()
                            .foregroundStyle(PanelSettingsTheme.secondary)
                    }
                    Group {
                        if selectedSection == .content { contentSettings }
                        else { appearanceSettings }
                    }
                    .id(selectedSection).transition(.opacity)
                    resetRow
                }
            }
            .environment(\.workbenchPreviewHeight, geometry.size.width >= 700 ? max(260, geometry.size.height - 50) : 400)
        }
        .font(MonitorDesktopTypography.body)
        .foregroundStyle(PanelSettingsTheme.primary)
        .tint(PanelSettingsTheme.clay)
        .animation(reduceMotion ? nil : PanelSettingsTheme.selectionMotion, value: selectedSection)
        .onDisappear { isAdjustingOpacity = false }
        .onChange(of: surfaceOpacity) { opacity in
            NotificationCenter.default.post(name: .glanceSurfaceOpacityDidChange, object: opacity)
        }
    }

    private var preferences: GlanceContentPreferences {
        .init(showPrimaryQuota: showPrimaryQuota,
              showCostEstimate: showCostEstimate, showCreditBalance: showCreditBalance,
              showDailyTokens: showDailyTokens, showThirtyDayTokens: showThirtyDayTokens,
              showTokenActivity: showTokenActivity, showResetEntry: showResetEntry, surfaceOpacity: surfaceOpacity)
    }

    private var availableProviders: [(provider: GlanceProvider, title: String)] {
        var list: [(GlanceProvider, String)] = [(.codex, "Codex")]
        if claude.enabled { list.append((.claude, "Claude")) }
        if grok.enabled { list.append((.grok, "Grok")) }
        if antigravity.enabled { list.append((.antigravity, "Antigravity")) }
        return list
    }

    private var resolvedProvider: GlanceProvider {
        .resolve(savedProvider, claudeEnabled: claude.enabled, grokEnabled: grok.enabled, antigravityEnabled: antigravity.enabled)
    }

    private var contentSettings: some View {
        VStack(alignment: .leading, spacing: 26) {
            if availableProviders.count > 1 {
                let stackSourceSegments = availableProviders.count >= 4
                PanelSettingsGroup(title: "来源视图", symbol: "square.stack.3d.up") {
                    SettingsRow(
                        symbol: "square.stack.3d.up",
                        title: "当前面板来源",
                        detail: "同步切换左侧实时预览与菜单栏玻璃面板当前展示的来源。",
                        stackedControl: stackSourceSegments
                    ) {
                        PanelSettingsSegments(
                            options: availableProviders.map(\.title),
                            selection: Binding(
                                get: {
                                    availableProviders.first(where: { $0.provider == resolvedProvider })?.title ?? "Codex"
                                },
                                set: { title in
                                    if let matched = availableProviders.first(where: { $0.title == title }) {
                                        savedProvider = matched.provider.rawValue
                                    }
                                }
                            ),
                            width: stackSourceSegments ? nil : CGFloat(availableProviders.count) * 76,
                            title: "当前面板来源"
                        )
                    }
                }.modifier(MonitorDesktopReveal(delay: 0.02))
            }
            PanelSettingsGroup(title: "额度", symbol: "gauge.with.dots.needle.33percent") {
                contentRow(
                    symbol: "gauge.with.dots.needle.33percent", title: "主额度窗口",
                    detail: "5 小时、每周及其他官方可用额度窗口（覆盖 Codex、Claude、Grok 与 Antigravity）。",
                    isOn: $showPrimaryQuota
                )
                rowDivider
                contentRow(
                    symbol: "creditcard", title: "Credits 余额",
                    detail: "可用的 Codex Credits、Grok 预付余额或 Antigravity AI Credits。",
                    isOn: $showCreditBalance
                )
                rowDivider
                contentRow(
                    symbol: "arrow.counterclockwise.circle", title: "额度重置入口",
                    detail: "Codex 额度卡次数、有效期与重置操作入口。",
                    isOn: $showResetEntry
                )
            }.modifier(MonitorDesktopReveal(delay: 0.04))
            PanelSettingsGroup(title: "用量", symbol: "chart.bar") {
                SettingsRow(symbol: "textformat.123", title: "数字单位", detail: countPreview, numericDetail: true) {
                    PanelSettingsSegments(options: ["万／亿", "K／M／B"], selection: Binding(
                        get: { countStyle == .chinese ? "万／亿" : "K／M／B" },
                        set: { countStyle = $0 == "万／亿" ? .chinese : .western; countStyle.save() }
                    ), title: "数字单位")
                }
                rowDivider
                contentRow(
                    symbol: "sun.max", title: "最近一天 Token",
                    detail: "最近一个统计日的用量。",
                    isOn: $showDailyTokens
                )
                rowDivider
                contentRow(
                    symbol: "calendar", title: "30 日 Token",
                    detail: "最近 30 个统计日的总用量。",
                    isOn: $showThirtyDayTokens
                )
                rowDivider
                contentRow(
                    symbol: "chart.bar.xaxis", title: "Token 活动图表",
                    detail: "最近 7 天用量，长周期请到监控中心查看。",
                    isOn: $showTokenActivity
                )
            }.modifier(MonitorDesktopReveal(delay: 0.08))
            PanelSettingsGroup(title: "成本", symbol: "dollarsign.circle") {
                contentRow(
                    symbol: "dollarsign.circle", title: "成本估算图表",
                    detail: "按参考 API 价格估算，非实际账单。",
                    isOn: $showCostEstimate
                )
            }.modifier(MonitorDesktopReveal(delay: 0.12))
        }
    }

    private var countPreview: String {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let lower = Calendar.current.date(byAdding: .day, value: -29, to: today)!
        switch resolvedProvider {
        case .codex:
            let accountID = UsageAccountSelection.currentAccountID(in: store.usageAccountOptions)
            let usage = accountID.map { store.costSnapshot.scope(for: $0).usage }
            let hasData = usage.map { !$0.activity.isEmpty || $0.day.tokens > 0 || $0.month.tokens > 0 } ?? false
            return SettingsSummaryText.countPreview(
                day: hasData ? usage.map { Int64($0.day.tokens) } : nil,
                month: hasData ? usage.map { Int64($0.month.tokens) } : nil,
                style: countStyle
            )
        case .claude:
            let snap = GlanceClaudeSnapshot(limits: claude.limits, usage: claude.usage, statusLineEnabled: claude.statusLineEnabled, now: now)
            return SettingsSummaryText.countPreview(
                day: snap.usageReady ? snap.todayTokens : nil,
                month: snap.usageReady ? snap.monthlyTokens : nil,
                style: countStyle
            )
        case .grok:
            guard let usage = grok.usage else {
                return SettingsSummaryText.countPreview(day: nil, month: nil, style: countStyle)
            }
            let dayTokens = Int64(usage.days.first { $0.date == today }?.tokens ?? 0)
            let monthTokens = Int64(usage.days.filter { $0.date >= lower && $0.date <= today }.reduce(0) { GrokJSON.add($0, $1.tokens) })
            return SettingsSummaryText.countPreview(day: dayTokens, month: monthTokens, style: countStyle)
        case .antigravity:
            guard let usage = antigravity.usage else {
                return SettingsSummaryText.countPreview(day: nil, month: nil, style: countStyle)
            }
            let dayTokens = Int64(usage.days.first { $0.date == today }?.tokens ?? 0)
            let monthTokens = Int64(usage.days.filter { $0.date >= lower && $0.date <= today }.reduce(0) { AntigravityMath.add($0, $1.tokens) })
            return SettingsSummaryText.countPreview(day: dayTokens, month: monthTokens, style: countStyle)
        }
    }

    private var resetRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if confirmingReset {
                Text("所有菜单栏面板设置将恢复默认").font(MonitorDesktopTypography.rowDetail).foregroundStyle(PanelSettingsTheme.secondary)
                Button("取消") { confirmingReset = false }.buttonStyle(PanelSettingsActionStyle())
            }
            Button(confirmingReset ? "确认恢复" : "恢复默认") {
                if confirmingReset {
                    let defaults = GlanceContentPreferences.defaults
                    showPrimaryQuota = defaults.showPrimaryQuota
                    showCostEstimate = defaults.showCostEstimate
                    showCreditBalance = defaults.showCreditBalance
                    showDailyTokens = defaults.showDailyTokens
                    showThirtyDayTokens = defaults.showThirtyDayTokens
                    showTokenActivity = defaults.showTokenActivity
                    showResetEntry = defaults.showResetEntry
                    surfaceOpacity = defaults.surfaceOpacity
                    countStyle = .chinese
                    countStyle.save()
                    confirmingReset = false
                } else {
                    confirmingReset = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { confirmingReset = false }
                }
            }
            .buttonStyle(PanelSettingsActionStyle())
            .foregroundStyle(confirmingReset ? MonitorDesktopTheme.caution : PanelSettingsTheme.primary)
        }.padding(.horizontal, 4)
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelSettingsGroup(title: "面板外观", symbol: "circle.lefthalf.filled") {
                opacityCard
            }.modifier(MonitorDesktopReveal(delay: 0.04))
            Label("仅影响菜单栏面板，灵动岛外观独立设置。", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(MonitorDesktopTheme.faintText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var visibleContentCount: Int {
        [
            showPrimaryQuota,
            showCostEstimate,
            showCreditBalance,
            showDailyTokens,
            showThirtyDayTokens,
            showTokenActivity,
            showResetEntry,
        ].filter { $0 }.count
    }

    private var rowDivider: some View { SettingsRowDivider() }

    private func contentRow(
        symbol: String,
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        SettingsRow(symbol: symbol, title: title, detail: detail) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(PanelSettingsToggleStyle())
                .accessibilityLabel(title)
                .accessibilityValue(isOn.wrappedValue ? "显示" : "隐藏")
        }
    }

    private var opacityCard: some View {
        IslandSettingsSliderRow(title: "面板不透明度", detail: "统一控制整个菜单栏面板的底色。",
            value: $surfaceOpacity, range: 0.10...0.90, step: 0.01,
            display: "\(Int((surfaceOpacity * 100).rounded()))%", lowerLabel: "更透明", upperLabel: "更深",
            onEditingChanged: { isAdjustingOpacity = $0 }, symbol: "circle.lefthalf.filled")
    }
}
