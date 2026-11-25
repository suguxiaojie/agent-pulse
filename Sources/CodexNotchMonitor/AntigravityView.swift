import Charts
import SwiftUI

struct AntigravityView: View {
    @ObservedObject var runtime: AntigravityRuntime
    @State private var days = 30
    @State private var now = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CountStyle.preferenceKey) private var countStyle = CountStyle.chinese.rawValue

    private var history: [AntigravityUsageSummary.Day] {
        let today = Calendar.current.startOfDay(for: now)
        let lower = Calendar.current.date(byAdding: .day, value: 1 - days, to: today)!
        return (runtime.usage?.days ?? []).filter { $0.date >= lower && $0.date <= today }.sorted { $0.date < $1.date }
    }

    private var tokenTotal: Int {
        history.reduce(0) { AntigravityMath.add($0, $1.tokens) }
    }

    private var hasUnpriced: Bool {
        history.contains { $0.hasUnpriced } || runtime.usage?.complete == false
    }

    private var allUnpricedZero: Bool {
        !history.isEmpty && history.allSatisfy { $0.hasUnpriced && $0.knownCost == 0 }
    }

    private var knownCostTotal: Double {
        history.reduce(0) { $0 + $1.knownCost }
    }

    private var costText: String {
        guard runtime.usage != nil else { return "—" }
        if allUnpricedZero { return "—" }
        return (hasUnpriced && !history.isEmpty ? "≥ " : "") + String(format: "$%.2f", knownCostTotal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionCard.modifier(MonitorDesktopReveal(delay: 0))
                if runtime.enabled {
                    quotaCard.modifier(MonitorDesktopReveal(delay: 0.04))
                    usageCard.modifier(MonitorDesktopReveal(delay: 0.08))
                    tasksCard.modifier(MonitorDesktopReveal(delay: 0.12))
                }
            }
            .padding(.bottom, 8)
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .onAppear {
            now = Date()
            runtime.refreshInstallation()
        }
        .onChange(of: runtime.quota?.capturedAt) { _ in now = Date() }
    }

    private var connectionCard: some View {
        PanelSettingsGroup(title: "Antigravity 连接", symbol: "sparkles") {
            SettingsRow(
                symbol: "sparkles",
                title: "任务与三端用量",
                detail: runtime.status + " · " + runtime.installation.summaryText
            ) {
                Toggle("启用 Antigravity", isOn: Binding(
                    get: { runtime.enabled },
                    set: { runtime.configure(enabled: $0, hooks: runtime.hooksEnabled, statusLine: runtime.statusLineEnabled) }
                ))
                .labelsHidden()
                .toggleStyle(PanelSettingsToggleStyle(onTitle: "开启", offTitle: "关闭"))
                .disabled(runtime.configuring)
            }
            SettingsRowDivider()
            SettingsRow(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "实时任务状态",
                detail: "同步 2.0 桌面端、IDE 与 CLI 的任务进度。"
            ) {
                Toggle("实时任务状态", isOn: Binding(
                    get: { runtime.hooksEnabled },
                    set: { runtime.configure(enabled: true, hooks: $0, approvals: runtime.approvalsEnabled, statusLine: runtime.statusLineEnabled) }
                ))
                .labelsHidden()
                .toggleStyle(PanelSettingsToggleStyle(onTitle: "开启", offTitle: "关闭"))
                .disabled(!runtime.enabled || runtime.configuring)
            }
            SettingsRowDivider()
            SettingsRow(
                symbol: "checkmark.shield",
                title: "灵动岛审批与提问回答",
                detail: "在灵动岛回答提问或确认操作，未处理时自动交回原客户端。"
            ) {
                Toggle("灵动岛审批与提问", isOn: Binding(
                    get: { runtime.approvalsEnabled },
                    set: { runtime.configure(enabled: true, hooks: runtime.hooksEnabled, approvals: $0, statusLine: runtime.statusLineEnabled) }
                ))
                .labelsHidden()
                .toggleStyle(PanelSettingsToggleStyle(onTitle: "开启", offTitle: "关闭"))
                .disabled(!runtime.enabled || !runtime.hooksEnabled || runtime.configuring)
            }
            SettingsRowDivider()
            SettingsRow(
                symbol: "gauge.with.dots.needle.50percent",
                title: "CLI 官方额度与 AI Credits",
                detail: "从 agy 同步官方剩余额度与 AI Credits，不影响原有状态栏。"
            ) {
                Toggle("采集官方额度", isOn: Binding(
                    get: { runtime.statusLineEnabled },
                    set: { runtime.configure(enabled: true, hooks: runtime.hooksEnabled, approvals: runtime.approvalsEnabled, statusLine: $0) }
                ))
                .labelsHidden()
                .toggleStyle(PanelSettingsToggleStyle(onTitle: "开启", offTitle: "关闭"))
                .disabled(!runtime.enabled || runtime.configuring)
            }
            Text("启用前自动备份原配置，停用自动还原；不读取账号凭据。")
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            if let error = runtime.error {
                HStack(spacing: 10) {
                    Text(error).font(MonitorDesktopTypography.metadata).foregroundStyle(MonitorDesktopTheme.caution)
                    Spacer()
                    Button("重试") { runtime.retry() }.buttonStyle(PanelSettingsActionStyle())
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var quotaCard: some View {
        let staleLimit = AntigravityQuotaSnapshot.uiStaleThreshold
        let activeWindows = runtime.statusLineEnabled ? (runtime.quota?.activeWindows(at: now, staleCutoff: staleLimit) ?? []) : []
        let stale = runtime.quota?.isStale(at: now, threshold: staleLimit) ?? false

        return VStack(alignment: .leading, spacing: 12) {
            MonitorCardHeader(symbol: "gauge.with.dots.needle.67percent", title: "Antigravity 官方额度") {
                HStack(spacing: 8) {
                    if let plan = runtime.quota?.resolvedPlan {
                        MonitorMetaChip(plan)
                    }
                    if let credits = runtime.quota?.aiCredits, runtime.statusLineEnabled, !stale {
                        MonitorMetaChip("AI Credits \(credits)")
                    }
                    MonitorRefreshButton(title: "刷新", loadingTitle: "刷新中", isRefreshing: runtime.scanning) {
                        runtime.refresh()
                    }
                    .accessibilityLabel("刷新 Antigravity 额度")
                }
            }

            if !runtime.statusLineEnabled {
                Text("开启上方「CLI 官方额度与 AI Credits」并在 agy 中对话后即可同步。")
                    .font(MonitorDesktopTypography.metadata)
                    .foregroundStyle(MonitorDesktopTheme.secondaryText)
            } else if activeWindows.isEmpty {
                MonitorCenterEmptyState(
                    symbol: "gauge.with.dots.needle.50percent",
                    title: "等待同步官方额度",
                    detail: "下次在 agy CLI 中运行对话时会自动同步当前额度与 AI Credits。"
                )
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(activeWindows.prefix(3)) { window in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(window.title)
                                    .font(MonitorDesktopTypography.metadataMedium)
                                    .foregroundStyle(MonitorDesktopTheme.secondaryText)
                                Spacer()
                                if let reset = window.resetsAt {
                                    Text(ChineseDisplayText.spacing(QuotaResetCountdown.text(until: reset, relativeTo: now)))
                                        .font(MonitorDesktopTypography.metadata)
                                        .foregroundStyle(MonitorDesktopTheme.tertiaryText)
                                }
                            }
                            Text("\(window.remainingPercent)%")
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .opacity(stale ? 0.55 : 1)
                            ProgressView(value: Double(window.remainingPercent), total: 100)
                                .tint(stale ? .gray : MonitorDesktopTheme.accent)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MonitorDesktopTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                HStack(spacing: 12) {
                    if let captured = runtime.quota?.capturedAt {
                        Text((stale ? "上次观测，非当前 · " : "观测于 ") + captured.formatted(date: .omitted, time: .shortened))
                    }
                    if runtime.quota?.useG1Credits == true {
                        Text("超额自动使用 AI Credits")
                    }
                }
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
            }
        }
        .modifier(MonitorCenterCard())
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonitorCardHeader(symbol: "chart.bar.xaxis", title: "三端本机用量与等价成本") {
                PanelSettingsSegments(
                    options: ["近 7 天", "近 30 天"],
                    selection: Binding(
                        get: { days == 7 ? "近 7 天" : "近 30 天" },
                        set: { days = $0 == "近 7 天" ? 7 : 30 }
                    ),
                    width: 148,
                    title: "统计周期"
                )
            }

            HStack(spacing: 14) {
                metricBox(title: "\(days) 天总 Token", value: runtime.usage == nil ? "—" : CountFormatter.display(Int64(tokenTotal)))
                metricBox(title: "API 等价成本", value: costText)
                metricBox(title: "三端累计会话", value: runtime.usage.map { "\($0.sessionCount)" } ?? "—")
            }

            if history.isEmpty {
                MonitorCenterEmptyState(
                    symbol: "chart.bar",
                    title: runtime.usage == nil ? "正在读取本机记录…" : "所选周期内暂无用量记录",
                    detail: "在 Antigravity 中发起对话后会自动统计本机用量。"
                )
            } else {
                Chart(history, id: \.date) { day in
                    BarMark(
                        x: .value("日期", day.date, unit: .day),
                        y: .value("Token", day.tokens)
                    )
                    .foregroundStyle(MonitorDesktopTheme.accent.gradient)
                    .cornerRadius(4)
                }
                .frame(height: 150)
            }

            let unpricedNote = (runtime.usage?.unpricedModels.isEmpty == false)
                ? "部分模型暂无公开单价，金额显示为已知下界。"
                : ""
            Text("成本按公开 API 费率估算，非订阅账单。" + unpricedNote)
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(MonitorCenterCard())
    }

    private var tasksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonitorCardHeader(symbol: "bolt.horizontal.circle", title: "实时任务") {
                HStack(spacing: 8) {
                    if !runtime.requests.isEmpty {
                        Button("待确认 \(runtime.requests.count)") { runtime.showRequests() }
                            .buttonStyle(PanelSettingsActionStyle())
                    }
                    if !runtime.rows.isEmpty {
                        MonitorMetaChip(ActivitySessionSnapshot.statusSummary(runtime.rows))
                    }
                }
            }
            if runtime.rows.isEmpty {
                MonitorCenterEmptyState(
                    symbol: "bolt.horizontal.circle",
                    title: "暂无运行中的任务",
                    detail: "在 Antigravity 中发起任务后，会在此与灵动岛同步显示。"
                )
            } else {
                ForEach(Array(runtime.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(MonitorDesktopTheme.hairline).frame(height: 0.5).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(runtime.surface(for: row).shortName) · \(row.projectName)")
                                .font(MonitorDesktopTypography.rowTitle)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(row.statusTitle)
                                .font(MonitorDesktopTypography.metadataMedium)
                                .foregroundStyle(statusColor(row))
                            if row.phase == .waitingApproval {
                                Button(runtime.fallbackTitle(for: row)) {
                                    runtime.openClient(for: row)
                                }
                                .buttonStyle(PanelSettingsActionStyle())
                            }
                        }
                        Text(row.title)
                            .font(MonitorDesktopTypography.metadata)
                            .foregroundStyle(MonitorDesktopTheme.secondaryText)
                            .lineLimit(1)
                        if !row.actionText.isEmpty && row.actionText != row.title {
                            Text(row.actionText)
                                .font(MonitorDesktopTypography.metadata)
                                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                                .lineLimit(2)
                        }
                        ForEach(row.recentSteps) { step in
                            Text("\(step.state.title) · \(step.title)")
                                .font(MonitorDesktopTypography.metadata)
                                .foregroundStyle(MonitorDesktopTheme.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .modifier(MonitorCenterCard())
    }

    private func metricBox(title: String, value: String) -> some View {
        let _ = countStyle
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorDesktopTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusColor(_ row: ActivitySessionSnapshot) -> Color {
        switch row.phase {
        case .waitingApproval: return MonitorDesktopTheme.accent
        case .failed: return MonitorDesktopTheme.caution
        case .completed: return MonitorDesktopTheme.positive
        default: return MonitorDesktopTheme.secondaryText
        }
    }
}

struct AntigravityGlanceContent: View {
    @ObservedObject var runtime: AntigravityRuntime
    let now: Date
    let weatherColor: Color
    let showsInlinePlanBadge: Bool
    let showQuota: Bool
    let showCost: Bool
    let showCreditBalance: Bool
    let showActivity: Bool
    let showDaily: Bool
    let showMonth: Bool
    @Binding var metric: String
    var onOpenCenter: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let staleLimit = AntigravityQuotaSnapshot.uiStaleThreshold
        let stale = runtime.quota?.isStale(at: now, threshold: staleLimit) ?? false

        VStack(spacing: GlanceLayout.moduleSpacing) {
            if showQuota {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let liveWindows = runtime.statusLineEnabled
                        ? (runtime.quota?.activeWindows(at: context.date, staleCutoff: staleLimit) ?? [])
                        : []
                    let rolledFiveHour = runtime.statusLineEnabled
                        ? runtime.quota?.rolledOverGeminiFiveHour(at: context.date, staleCutoff: staleLimit)
                        : nil
                    let liveStale = runtime.quota?.isStale(at: context.date, threshold: staleLimit) ?? false
                    if let primary = liveWindows.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                        let rlWindow = RateLimitWindow(
                            usedPercent: Int(primary.usedPercent.rounded()),
                            windowDurationMinutes: primary.durationMinutes,
                            resetsAt: primary.resetsAt
                        )
                        let forecast = QuotaPaceForecast(window: rlWindow, now: context.date)
                        let copy = forecast.copy(resetsAt: primary.resetsAt, now: context.date)
                        let secondaryWindows = liveWindows.filter { $0.id != primary.id }
                        let geminiSecondary = secondaryWindows.first { !$0.id.lowercased().contains("3p") }
                        let partnerWindows = secondaryWindows.filter { $0.id.lowercased().contains("3p") }
                        let limitingPartner = partnerWindows.min { $0.remainingPercent < $1.remainingPercent }

                        let secondaryRing: Int? = {
                            if let gem = geminiSecondary { return gem.remainingPercent }
                            if rolledFiveHour != nil { return 100 }
                            return limitingPartner?.remainingPercent
                        }()

                        let footerLeftText: String? = {
                            if let gem = geminiSecondary {
                                let shortTitle = gem.durationMinutes == 300 ? "5h 额度" : (gem.durationMinutes == 10_080 ? "每周额度" : gem.title)
                                return "\(shortTitle) \(gem.remainingPercent)% · \(shortResetText(gem.resetsAt, now: context.date))"
                            }
                            if rolledFiveHour != nil {
                                return "5h 额度 100% · 已重置"
                            }
                            if let credits = runtime.quota?.aiCredits, !liveStale, runtime.quota?.useG1Credits == true {
                                return "AI Credits \(CountFormatter.display(Int64(credits)))"
                            }
                            return nil
                        }()

                        let footerRightText: String? = {
                            if let partner = limitingPartner {
                                return "合作模型 \(partner.remainingPercent)%"
                            }
                            if let credits = runtime.quota?.aiCredits, !liveStale, runtime.quota?.useG1Credits == true, footerLeftText?.hasPrefix("AI Credits") != true {
                                return "Credits \(CountFormatter.display(Int64(credits)))"
                            }
                            return nil
                        }()

                        GlanceHeroQuotaCard(
                            title: primary.title,
                            remainingPercent: primary.remainingPercent,
                            primaryCopy: copy.primary,
                            secondaryCopy: copy.secondary + observationSuffix(stale: liveStale),
                            weatherColor: weatherColor,
                            secondaryRingPercent: secondaryRing,
                            footerLeft: footerLeftText,
                            footerRight: footerRightText,
                            isStale: liveStale
                        ) {
                            if showsInlinePlanBadge, let plan = runtime.quota?.resolvedPlan {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(liveStale ? Color.orange.opacity(0.88) : Color.green.opacity(0.90))
                                        .frame(width: 5, height: 5)
                                    Text(plan)
                                        .font(.system(size: 9, weight: .medium))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(FloatingSurfaceTheme.chipFill(colorScheme), in: Capsule())
                            }
                        }
                    } else if let rolled = rolledFiveHour {
                        GlanceHeroQuotaCard(
                            title: rolled.title,
                            remainingPercent: 100,
                            primaryCopy: "当前 5 小时周期已重置",
                            secondaryCopy: "待下次 agy 对话同步新周期重置时间",
                            weatherColor: weatherColor
                        ) {
                            EmptyView()
                        }
                    } else {
                        GlanceEmptyQuotaCard(
                            title: "Antigravity 额度",
                            message: !runtime.statusLineEnabled
                                ? "开启 CLI 状态栏后可同步 Antigravity 官方额度"
                                : "等待 agy CLI 下一次输出同步官方额度"
                        ) {
                            EmptyView()
                        } action: {
                            if !runtime.statusLineEnabled, let onOpenCenter {
                                Button("打开设置 ›") { onOpenCenter() }
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(weatherColor)
                                    .buttonStyle(FloatingSurfaceButtonStyle())
                            }
                        }
                    }
                }
            }

            if showCost || showActivity {
                let cost = showCost && (!showActivity || metric != "token")
                let days = runtime.usage?.days ?? []
                let unpricedModels = runtime.usage?.unpricedModels ?? []
                GlanceWeatherStrip(
                    buckets: GlanceDayStrip.buckets(
                        samples: days.map { day in
                            .init(date: day.date, value: cost ? day.knownCost : Double(day.tokens))
                        },
                        now: now
                    ),
                    isCost: cost,
                    isReady: runtime.usage != nil,
                    showsSelector: showCost && showActivity,
                    metric: $metric,
                    color: weatherColor,
                    unknownModels: unpricedModels,
                    loadingText: "正在统计 Antigravity 用量…",
                    tokenSourceLabel: "本机三端用量",
                    unpricedDates: Set(days.filter { $0.hasUnpriced && $0.knownCost == 0 }.map(\.date)),
                    unpricedHelpText: unpricedModels.isEmpty
                        ? "Antigravity 本地日志包含未标明模型或未公开 API 单价的步骤，对应部分保留金额下界。"
                        : "本地日志包含未公开 API 单价或未标明模型的子代理／记录：" + unpricedModels.joined(separator: "、")
                )
            }

            dataBlocks(stale: stale)
        }
    }

    @ViewBuilder
    private func dataBlocks(stale: Bool) -> some View {
        let ready = runtime.usage != nil
        let today = Calendar.current.startOfDay(for: now)
        let lower = Calendar.current.date(byAdding: .day, value: -29, to: today)!
        let todayDay = runtime.usage?.days.first { $0.date == today }
        let todayTokens = todayDay?.tokens ?? 0
        let todayCost: Double? = {
            guard runtime.usage != nil else { return nil }
            guard let todayDay else { return 0 }
            return todayDay.cost
        }()
        let todayCostLowerBound = (todayDay?.hasUnpriced == true) && ((todayDay?.knownCost ?? 0) > 0)
        let monthTokens = (runtime.usage?.days ?? [])
            .filter { $0.date >= lower && $0.date <= today }
            .reduce(0) { AntigravityMath.add($0, $1.tokens) }
        let visibleCredits = (showCreditBalance && runtime.statusLineEnabled && !stale) ? runtime.quota?.aiCredits : nil

        if visibleCredits != nil || showCost || showDaily || showMonth {
            HStack(spacing: 6) {
                if let credits = visibleCredits {
                    dataBlock("AI Credits", value: CountFormatter.display(Int64(credits)))
                } else if showCost {
                    dataBlock("今日成本", value: ready ? GlanceDayStrip.metricCardCostText(todayCost, lowerBound: todayCostLowerBound) : "—")
                }
                if showDaily {
                    dataBlock("今日 Token", value: ready ? GlanceDayStrip.tokenText(Double(todayTokens)) : "—")
                }
                if showMonth {
                    dataBlock("30 日 Token", value: ready ? GlanceDayStrip.tokenText(Double(monthTokens)) : "—")
                }
            }
        }
    }

    private func shortResetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "未知" }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h 后" : "\(days) 天后" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m 后" : "\(hours) 小时后" }
        return "\(max(1, minutes)) 分钟后"
    }

    private func dataBlock(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9)).foregroundStyle(secondaryText)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .glanceReadableText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .weatherModule()
        .accessibilityElement(children: .combine)
    }

    private func observationSuffix(stale: Bool) -> String {
        guard stale, let capturedAt = runtime.quota?.capturedAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return " · 数据于 " + formatter.string(from: capturedAt)
    }

    private var secondaryText: Color {
        FloatingSurfaceTheme.detail(colorScheme)
    }
}

struct AntigravityRequestsView: View {
    @ObservedObject var runtime: AntigravityRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Antigravity 待处理请求")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(runtime.requests.count) 项等待确认")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if runtime.requests.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("当前没有等待处理的 Antigravity 审批或提问")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(runtime.requests) { req in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(req.isQuestion ? "交互提问 · \(req.surface.displayName)" : "工具审批 · \(req.displayToolName)")
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(req.surface.shortName)
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.14), in: Capsule())
                                }
                                if !req.cwd.isEmpty {
                                    Text("工作区：" + req.cwd)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                ScrollView(.horizontal, showsIndicators: true) {
                                    Text(req.detailJSON)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(10)
                                }
                                .frame(maxHeight: 200)
                                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                                HStack(spacing: 8) {
                                    if !req.isQuestion {
                                        Button("批准一次") {
                                            runtime.respond(req.id, choice: .approveOnce)
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                    Button(req.isQuestion ? "取消提问" : "拒绝", role: .destructive) {
                                        runtime.respond(req.id, choice: .deny)
                                    }
                                    Spacer()
                                    Button("在 \(req.surface.displayName) 中处理") {
                                        runtime.returnToClient(req.id)
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 420)
    }
}
