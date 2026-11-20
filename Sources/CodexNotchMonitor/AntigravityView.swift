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
                title: "三端实时生命周期 Hook",
                detail: "在 ~/.gemini/config/hooks.json 管理专属键，同时覆盖 2.0 桌面端、IDE 与 CLI，不安装 PreToolUse、不自动批准。"
            ) {
                Toggle("三端实时 Hook", isOn: Binding(
                    get: { runtime.hooksEnabled },
                    set: { runtime.configure(enabled: true, hooks: $0, statusLine: runtime.statusLineEnabled) }
                ))
                .labelsHidden()
                .toggleStyle(PanelSettingsToggleStyle(onTitle: "开启", offTitle: "关闭"))
                .disabled(!runtime.enabled || runtime.configuring)
            }
            SettingsRowDivider()
            SettingsRow(
                symbol: "gauge.with.dots.needle.50percent",
                title: "CLI 官方额度与 AI Credits",
                detail: "通过 agy 状态栏采集多模型池剩余比例与 AI Credits，原样转发原有状态栏输出。"
            ) {
                Toggle("采集官方额度", isOn: Binding(
                    get: { runtime.statusLineEnabled },
                    set: { runtime.configure(enabled: true, hooks: runtime.hooksEnabled, statusLine: $0) }
                ))
                .labelsHidden()
                .toggleStyle(PanelSettingsToggleStyle(onTitle: "开启", offTitle: "关闭"))
                .disabled(!runtime.enabled || runtime.configuring)
            }
            Text("首次启用前自动备份 hooks.json 与 settings.json，仅管理 Pulse 自己的配置项；停用完整恢复原状态栏并移除专属 Hook。不读取账号凭据或邮箱；交互提问与权限确认均在原客户端完成。")
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
                    Button(runtime.scanning ? "刷新中…" : "刷新") { runtime.refresh() }
                        .buttonStyle(PanelSettingsActionStyle())
                        .disabled(runtime.scanning)
                }
            }

            if !runtime.statusLineEnabled {
                Text("开启「CLI 官方额度与 AI Credits」并在 agy 中对话后即可同步真实配额。")
                    .font(MonitorDesktopTypography.metadata)
                    .foregroundStyle(MonitorDesktopTheme.secondaryText)
            } else if activeWindows.isEmpty {
                MonitorCenterEmptyState(
                    symbol: "gauge.with.dots.needle.50percent",
                    title: "等待状态栏同步官方额度",
                    detail: "下次在 agy CLI 中运行对话时，状态栏会自动将当前套餐配额与 AI Credits 同步至 Pulse。"
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
                    if let useCredits = runtime.quota?.useG1Credits {
                        Text(useCredits ? "AI Credits 超额兜底已开启" : "AI Credits 超额兜底未开启")
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
                    title: runtime.usage == nil ? "正在扫描本机记录…" : "所选周期内没有 Antigravity 用量记录",
                    detail: "自动聚合 ~/.gemini 下 Antigravity 2.0、IDE 与 CLI 的本地转录。"
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

            let unpricedNote: String = {
                guard let models = runtime.usage?.unpricedModels, !models.isEmpty else { return "" }
                return "未公开单价或未标明模型的记录（如 \(models.prefix(3).joined(separator: "、"))）保留金额下界，不按 $0 计入。"
            }()
            Text("按输入 + 缓存读取 + 输出统计三端真实 Token；成本仅对公开标准费率模型折算，非 Google AI 订阅账单。" + unpricedNote)
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(MonitorCenterCard())
    }

    private var tasksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonitorCardHeader(symbol: "bolt.horizontal.circle", title: "实时任务") {
                if !runtime.rows.isEmpty {
                    MonitorMetaChip(ActivitySessionSnapshot.statusSummary(runtime.rows))
                }
            }
            if runtime.rows.isEmpty {
                MonitorCenterEmptyState(
                    symbol: "bolt.horizontal.circle",
                    title: "当前没有已确认的活动任务",
                    detail: "通过进程文件锁、生命周期 Hook 与本地转录核对 2.0 桌面端、IDE 与 CLI 的运行任务。"
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
                    VStack(alignment: .leading, spacing: 7) {
                        if let primary = liveWindows.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                            let rlWindow = RateLimitWindow(
                                usedPercent: Int(primary.usedPercent.rounded()),
                                windowDurationMinutes: primary.durationMinutes,
                                resetsAt: primary.resetsAt
                            )
                            let forecast = QuotaPaceForecast(window: rlWindow, now: context.date)
                            let copy = forecast.copy(resetsAt: primary.resetsAt, now: context.date)
                            HStack(spacing: 5) {
                                Text(primary.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
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
                                    .padding(.vertical, 5)
                                    .background(FloatingSurfaceTheme.chipFill(colorScheme), in: Capsule())
                                }
                            }

                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(primary.remainingPercent)")
                                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                Text("%")
                                    .font(.system(size: 27, weight: .medium, design: .rounded))
                                    .foregroundStyle(secondaryText)
                            }
                            .glanceReadableText()
                            .opacity(liveStale ? 0.58 : 1)
                            .accessibilityLabel((liveStale ? "上次观测，非当前。" : "") + "剩余 \(primary.remainingPercent)%")

                            Text(copy.primary)
                                .font(.system(size: 12.5, weight: .medium))
                                .glanceReadableText()
                            Text(copy.secondary + observationSuffix(stale: liveStale))
                                .font(.system(size: 10.5))
                                .foregroundStyle(tertiaryText)

                            if let rolled = rolledFiveHour {
                                Text("\(rolled.title) 100% · 已重置（待下次对话同步）")
                                    .font(.system(size: 10))
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                            }

                            let secondaryWindows = liveWindows.filter { $0.id != primary.id }
                            let partnerWindows = secondaryWindows.filter { $0.id.lowercased().contains("3p") }
                            let collapseUnusedPartners = partnerWindows.count >= 2 && partnerWindows.allSatisfy { $0.remainingPercent == 100 }
                            ForEach(secondaryWindows.filter { !collapseUnusedPartners || !$0.id.lowercased().contains("3p") }) { other in
                                Text("\(other.title) \(other.remainingPercent)% · \(resetText(other.resetsAt, now: context.date))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                            }
                            if collapseUnusedPartners {
                                Text("合作模型额度 100% · 5 小时与每周均未使用")
                                    .font(.system(size: 10))
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                            }

                            if let credits = runtime.quota?.aiCredits, !liveStale, runtime.quota?.useG1Credits == true {
                                Text("AI Credits 超额兜底已开启 · 余额 \(CountFormatter.display(Int64(credits)))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                            }
                        } else if let rolled = rolledFiveHour {
                            Text(rolled.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(secondaryText)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("100")
                                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                Text("%")
                                    .font(.system(size: 27, weight: .medium, design: .rounded))
                                    .foregroundStyle(secondaryText)
                            }
                            .glanceReadableText()
                            Text("当前 5 小时周期已重置")
                                .font(.system(size: 12.5, weight: .medium))
                                .glanceReadableText()
                            Text("待下次 agy 对话同步新周期重置时间")
                                .font(.system(size: 10.5))
                                .foregroundStyle(tertiaryText)
                        } else {
                            Text("Antigravity 额度")
                                .font(FloatingSurfaceTypography.section)
                            Text(!runtime.statusLineEnabled
                                 ? "开启 CLI 状态栏后可同步 Antigravity 官方额度"
                                 : "等待 agy CLI 下一次输出同步官方额度")
                                .font(FloatingSurfaceTypography.label)
                                .foregroundStyle(tertiaryText)
                            if !runtime.statusLineEnabled, let onOpenCenter {
                                Button("打开 Antigravity 设置") { onOpenCenter() }
                                    .buttonStyle(FloatingSurfaceButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 156, alignment: .leading)
                    .padding(.vertical, 6)
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

            if runtime.usage != nil {
                dataBlocks(stale: stale)
            } else if !showCost && !showActivity {
                Text("正在统计 Antigravity 用量…")
                    .font(FloatingSurfaceTypography.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .weatherModule()
            }
        }
    }

    @ViewBuilder
    private func dataBlocks(stale: Bool) -> some View {
        let today = Calendar.current.startOfDay(for: now)
        let lower = Calendar.current.date(byAdding: .day, value: -29, to: today)!
        let todayTokens = runtime.usage?.days.first { $0.date == today }?.tokens ?? 0
        let monthTokens = (runtime.usage?.days ?? [])
            .filter { $0.date >= lower && $0.date <= today }
            .reduce(0) { AntigravityMath.add($0, $1.tokens) }
        let visibleCredits = (showCreditBalance && runtime.statusLineEnabled && !stale) ? runtime.quota?.aiCredits : nil

        if visibleCredits != nil || showDaily || showMonth {
            HStack(spacing: 6) {
                if let credits = visibleCredits {
                    dataBlock("AI Credits", value: CountFormatter.display(Int64(credits)))
                }
                if showDaily {
                    dataBlock("今日 Token", value: GlanceDayStrip.tokenText(Double(todayTokens)))
                }
                if showMonth {
                    dataBlock("30 日 Token", value: GlanceDayStrip.tokenText(Double(monthTokens)))
                }
                if visibleCredits == nil {
                    dataBlock(
                        "累计 Token",
                        value: runtime.usage.map { GlanceDayStrip.tokenText(Double($0.lifetimeTokens)) } ?? "—"
                    )
                }
            }
        }
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

    private func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "重置时间未知" }
        return ChineseDisplayText.spacing(QuotaResetCountdown.text(until: date, relativeTo: now))
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

    private var tertiaryText: Color {
        FloatingSurfaceTheme.secondary(colorScheme)
    }
}
