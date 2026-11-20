import SwiftUI

private protocol IslandUsageFormatting {}
private extension IslandUsageFormatting {
    var secondary: Color { FloatingSurfaceTheme.secondary() }
    func tokens(_ value: Int?) -> String {
        value.map { CountFormatter.display(Int64($0)) } ?? "—"
    }
    func money(_ value: Double?) -> String { value.map { $0.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))) } ?? "—" }
    func heading(_ value: String) -> some View {
        Text(value).font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
    }
    func surface<Content: View>(verticalPadding: CGFloat = 14, @ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 14).padding(.vertical, verticalPadding).frame(maxWidth: .infinity, alignment: .leading)
            .islandGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                         tint: Color(white: 0.025).opacity(0.90), solidTint: Color(white: 0.025))
    }
}

struct ClaudeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        guard radius > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let lengths: [CGFloat] = [1, 0.84, 0.96, 0.78, 0.92, 0.86]
        var path = Path(ellipseIn: CGRect(x: center.x - radius * 0.16, y: center.y - radius * 0.16,
                                          width: radius * 0.32, height: radius * 0.32))
        for index in 0..<12 {
            let angle = CGFloat(index) * .pi / 6 - .pi / 2
            let dx = cos(angle), dy = sin(angle)
            func point(_ distance: CGFloat, _ halfWidth: CGFloat) -> CGPoint {
                CGPoint(x: center.x + radius * (dx * distance - dy * halfWidth),
                        y: center.y + radius * (dy * distance + dx * halfWidth))
            }
            let tip = min(0.98, lengths[index % lengths.count])
            path.move(to: point(0.12, 0.11))
            path.addLine(to: point(tip, 0.025))
            path.addLine(to: point(tip, -0.025))
            path.addLine(to: point(0.12, -0.11))
            path.closeSubpath()
        }
        return path
    }
}

struct AntigravityMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        guard radius > 0 else { return Path() }
        let cx = rect.midX, cy = rect.midY
        let outer = radius * 0.94
        let waist = radius * 0.28
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - outer))
        path.addQuadCurve(to: CGPoint(x: cx + outer, y: cy), control: CGPoint(x: cx + waist, y: cy - waist))
        path.addQuadCurve(to: CGPoint(x: cx, y: cy + outer), control: CGPoint(x: cx + waist, y: cy + waist))
        path.addQuadCurve(to: CGPoint(x: cx - outer, y: cy), control: CGPoint(x: cx - waist, y: cy + waist))
        path.addQuadCurve(to: CGPoint(x: cx, y: cy - outer), control: CGPoint(x: cx - waist, y: cy - waist))
        path.closeSubpath()
        return path
    }
}

struct IslandUsageProviderSwitch: View {
    @ObservedObject var model: ActivityIslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    private var visibleProviders: [IslandUsageProvider] {
        IslandUsageProvider.allCases.filter {
            ($0 != .grok || model.grokEnabled) && ($0 != .antigravity || model.antigravityEnabled)
        }
    }

    private var controlWidth: CGFloat {
        switch visibleProviders.count {
        case ..<3: return 240
        case 3: return 330
        default: return 374
        }
    }

    private func switchLabel(for provider: IslandUsageProvider, compact: Bool) -> String {
        guard compact else { return provider.rawValue }
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .antigravity: return "Antigravity"
        }
    }

    var body: some View {
        let providers = visibleProviders
        let compact = providers.count >= 4
        HStack(spacing: 0) {
            ForEach(providers, id: \.self) { provider in
                let disabled = (provider == .claude && !model.claudeEnabled)
                    || (provider == .grok && !model.grokEnabled)
                    || (provider == .antigravity && !model.antigravityEnabled)
                    || model.resetBusy || model.resetConfirmationPresented
                Button {
                    withAnimation(reduceMotion ? nil : FloatingSurfaceTheme.selectionMotion) { model.selectUsageProvider(provider) }
                } label: {
                    HStack(spacing: compact ? 4 : 5) {
                        if provider == .codex {
                            if let icon = ActivityIslandPreviewAssets.codexIcon {
                                Image(nsImage: icon).renderingMode(.template).resizable().scaledToFit()
                                    .frame(width: 13, height: 13).accessibilityHidden(true)
                            }
                        } else if provider == .grok {
                            Image(systemName: "sparkle").font(.system(size: 12)).accessibilityHidden(true)
                        } else if provider == .antigravity {
                            AntigravityMarkShape().fill(Color(red: 0.494, green: 0.620, blue: 1.0))
                                .frame(width: 13, height: 13)
                                .opacity(model.usageProvider == provider ? 1 : 0.65)
                                .saturation(disabled ? 0 : 1).accessibilityHidden(true)
                        } else {
                            ClaudeMarkShape().fill(Color(red: 0.851, green: 0.467, blue: 0.341))
                                .frame(width: 13, height: 13)
                                .opacity(model.usageProvider == provider ? 1 : 0.6)
                                .saturation(disabled ? 0 : 1).accessibilityHidden(true)
                        }
                        Text(switchLabel(for: provider, compact: compact)).font(FloatingSurfaceTypography.control)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle(model.usageProvider == provider ? FloatingSurfaceTheme.primary() : FloatingSurfaceTheme.secondary())
                        .background {
                            if model.usageProvider == provider {
                                Capsule().fill(FloatingSurfaceTheme.accent().opacity(0.20))
                                    .matchedGeometryEffect(id: "provider-selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(FloatingSurfaceButtonStyle())
                    .disabled(disabled)
                    .accessibilityLabel(provider.rawValue)
                    .accessibilityValue(model.usageProvider == provider ? "已选择" : "未选择")
                    .accessibilityAddTraits(model.usageProvider == provider ? .isSelected : [])
                    .help(provider == .claude && !model.claudeEnabled ? "请先在监控中心启用 Claude Code" : "查看 " + provider.rawValue + " 用量")
            }
        }.frame(width: controlWidth, height: 28)
            .islandGlass(Capsule(), tint: .black.opacity(0.28))
            .animation(reduceMotion ? nil : FloatingSurfaceTheme.selectionMotion, value: model.usageProvider)
            .accessibilityElement(children: .contain).accessibilityLabel("用量来源")
    }
}

struct IslandUsageSourceCard: View, IslandUsageFormatting {
    let source: IslandUsagePresentation.Source
    let playbackVisible: Bool
    let flightActive: Bool
    let onReset: () -> Void
    var body: some View {
        switch source {
        case .codex(let planName, let balance, let resetCount):
            codexAccountCard(planName: planName, balance: balance, resetCount: resetCount)
        case .claude:
            surface {
                VStack(alignment: .leading, spacing: 8) {
                    heading("用量来源")
                    Text("Claude Code").font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 4)
                    heading("额度 · 官方状态栏")
                    heading("历史 · 本机全部会话（含子 Agent）")
                }.frame(maxHeight: .infinity, alignment: .topLeading)
            }.help("历史为本机全部会话，含子 Agent；账号归属未推断。")
        case .grok(let plan, let shared, let prepaid):
            surface {
                VStack(alignment: .leading, spacing: 8) {
                    heading("Grok 官方额度")
                    Text(plan).font(.system(size: 15, weight: .semibold))
                    heading(shared == true ? "统一共享额度池" : "订阅额度")
                    Spacer(minLength: 4)
                    heading("预付余额 · " + (prepaid.map { String(format: "$%.2f", Double($0) / 100) } ?? "—"))
                    heading("历史 · 本机记录，非订阅账单")
                }.frame(maxHeight: .infinity, alignment: .topLeading)
            }
        case .antigravity(let plan, let credits, let useG1Credits):
            surface {
                VStack(alignment: .leading, spacing: 8) {
                    heading("Antigravity 官方额度")
                    Text(plan).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    heading("AI Credits · " + (credits.map(String.init) ?? "—"))
                    Spacer(minLength: 4)
                    heading(useG1Credits == true ? "超额自动使用 Credits" : "额度 · CLI 状态栏同步")
                    heading("历史 · 本机三端记录")
                }.frame(maxHeight: .infinity, alignment: .topLeading)
            }.help("覆盖本机 Antigravity 2.0、IDE 与 CLI 记录；AI Credits 与订阅配额分开统计。")
        }
    }
    private func codexAccountCard(planName: String, balance: String?, resetCount: Int?) -> some View {
        surface {
            VStack(alignment: .leading, spacing: 6) {
                heading("账户")
                Text(planName).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 2)
                HStack { heading("积分余额"); Spacer(); Text(CreditBalanceFormatter.summary(balance)).font(FloatingSurfaceTypography.metadata).lineLimit(1).minimumScaleFactor(0.7) }
                    .help("完整余额：" + CreditBalanceFormatter.string(balance))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("积分余额")
                    .accessibilityValue(CreditBalanceFormatter.string(balance))
                Divider().overlay(FloatingSurfaceTheme.separator())
                Button { onReset() } label: {
                    HStack {
                        DashboardResetTicket(playbackEnabled: playbackVisible && !flightActive)
                            .opacity(flightActive ? 0 : 1)
                            .anchorPreference(key: DashboardResetTicketAnchors.self, value: .bounds) { [.usage: $0] }
                            .accessibilityHidden(true)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            heading("额度重置")
                            Text(resetCount.map { "\($0) 次" } ?? "—").font(FloatingSurfaceTypography.body)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(FloatingSurfaceButtonStyle()).help("在灵动岛内查看重置次数与有效期，点击票卡不会消耗次数")
            }.frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct IslandUsageMetricStrip: View, IslandUsageFormatting {
    @AppStorage(CountStyle.preferenceKey) private var countStyle = CountStyle.chinese.rawValue
    let metrics: [IslandUsagePresentation.Metric]
    var body: some View {
        surface(verticalPadding: 10) {
            HStack(spacing: 14) {
                ForEach(metrics.indices, id: \.self) { index in
                    if index > 0 { Rectangle().fill(FloatingSurfaceTheme.separator()).frame(width: 1) }
                    VStack(alignment: .leading, spacing: 6) {
                        heading(metrics[index].title).lineLimit(1).minimumScaleFactor(0.75)
                        Text(tokens(metrics[index].tokens)).foregroundStyle(FloatingSurfaceTheme.usageData())
                            .font(FloatingSurfaceTypography.primaryMetric).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        if let date = metrics[index].dateTag {
                            Text(date).font(FloatingSurfaceTypography.metadata).foregroundStyle(secondary)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IslandUsageQuotaRow: View, IslandUsageFormatting {
    let quotas: [IslandUsagePresentation.Quota]
    let now: Date
    var body: some View {
        HStack(spacing: 10) { ForEach(quotas.indices, id: \.self) { quotaCard(quotas[$0]) } }
    }
    private func quotaCard(_ quota: IslandUsagePresentation.Quota) -> some View {
        surface {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack { heading(quota.title).fixedSize(); Spacer(minLength: 10); heading(quota.freshness.observationLabel(now: now) ?? reset(quota.resetsAt)).fixedSize() }
                    VStack(alignment: .leading, spacing: 4) { heading(quota.title); heading(quota.freshness.observationLabel(now: now) ?? reset(quota.resetsAt)) }
                }
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 10) {
                        percentageRow(quota, showsRemaining: true, showsUsed: true)
                        progress(quota)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        percentageRow(quota, showsRemaining: false, showsUsed: true)
                        progress(quota)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        percentageRow(quota, showsRemaining: false, showsUsed: false)
                        progress(quota)
                        usedLabel(quota)
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .topLeading)
        }.opacity(quota.freshness.isStale ? 0.55 : 1)
            .help(reset(quota.resetsAt))
            .accessibilityElement(children: .combine)
            .accessibilityValue(quota.freshness.isStale ? "上次观测，非当前" : "")
    }
    private func percentageRow(_ quota: IslandUsagePresentation.Quota, showsRemaining: Bool, showsUsed: Bool) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(quota.remainingPercent.map { "\($0)%" } ?? "—")
                .font(FloatingSurfaceTypography.primaryMetric).monospacedDigit().fixedSize()
            if showsRemaining && quota.remainingPercent != nil { heading("剩余").fixedSize() }
            Spacer(minLength: 10)
            if showsUsed { usedLabel(quota) }
        }
    }
    private func usedLabel(_ quota: IslandUsagePresentation.Quota) -> some View {
        heading(quota.usedPercent.map { "已使用 \($0)%" } ?? "—").fixedSize()
    }
    private func progress(_ quota: IslandUsagePresentation.Quota) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(FloatingSurfaceTheme.track())
                Capsule().fill(quota.freshness.isStale ? secondary : FloatingSurfaceTheme.quotaHealth(quota.remainingPercent))
                    .frame(width: proxy.size.width * CGFloat(quota.remainingPercent ?? 0) / 100)
            }
        }.frame(height: 8).accessibilityHidden(true)
    }
    private func reset(_ date: Date?) -> String {
        guard let date else { return "重置时间 —" }
        let hours = max(0, Int(ceil(date.timeIntervalSince(now) / 3600)))
        return ChineseDisplayText.spacing(hours >= 24 ? "\(hours / 24)天\(hours % 24)小时后重置" : "\(hours)小时后重置")
    }
}

struct IslandUsageTrendCard: View, IslandUsageFormatting {
    @AppStorage(CountStyle.preferenceKey) private var countStyle = CountStyle.chinese.rawValue
    let presentation: IslandUsagePresentation
    let width: CGFloat
    let now: Date
    @Binding var mode: IslandDashboardHeatmap.Mode
    @Binding var selectedCost: Date?
    @Binding var selectedActivity: String?
    @Binding var hoveredCost: Date?
    @Binding var hoveredActivity: Int?
    private var chart: IslandUsagePresentation.Cost { presentation.cost }
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()
    private static let abbreviatedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        surface(verticalPadding: 8) {
            VStack(spacing: 8) {
                costCard.zIndex(hoveredCost == nil ? 0 : 1)
                Divider().overlay(FloatingSurfaceTheme.separator())
                IslandUsageHeatmapCard(
                    activity: presentation.activity,
                    lifetimeTokens: presentation.lifetimeTokens,
                    activityHelp: presentation.activityHelp,
                    width: width,
                    endingAt: max(now, presentation.activity.last?.date ?? now),
                    generation: generation,
                    countStyle: countStyle,
                    mode: $mode,
                    selectedActivity: $selectedActivity,
                    hoveredActivity: $hoveredActivity
                )
                .zIndex(hoveredActivity == nil ? 0 : 1)
            }
        }
        .onChange(of: width) { _ in hoveredCost = nil; hoveredActivity = nil }
        .onDisappear { hoveredCost = nil; hoveredActivity = nil }
    }
    private var contentWidth: CGFloat { width - 56 }
    private var costCellSize: CGFloat { max(8, IslandDashboardHeatmap.cellSize(width: contentWidth - 28)) }
    private var costPlotWidth: CGFloat { CGFloat(chart.days.count) * costCellSize + CGFloat(max(0, chart.days.count - 1)) * 3 }
    private var costViewport: CGFloat { min(costPlotWidth, max(104, contentWidth - 28 - 208 - 28)) }
    private var summaryWidth: CGFloat { max(1, (contentWidth - 28 - costViewport - 28) / 2) }
    private var generation: String { "\(presentation.provider.rawValue)-\(presentation.supportsReset)-\(chart.days.last?.date.timeIntervalSinceReferenceDate ?? 0)" }

    private func costDayIndex(at point: CGPoint, count: Int, cellWidth: CGFloat, height: CGFloat) -> Int? {
        guard count > 0, point.x >= 0, point.y >= 0, point.y <= height else { return nil }
        let stride = cellWidth + 3
        let index = Int(point.x / stride)
        guard (0..<count).contains(index), point.x - CGFloat(index) * stride <= cellWidth + 1.5 else { return nil }
        return index
    }

    private var costCard: some View {
        let chart = self.chart
        let selected = chart.days.first { $0.date == selectedCost }
        return Group {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    heading(chart.title)
                    Text((chart.totalIsLowerBound && chart.total != nil ? "≥" : "") + money(chart.total)).foregroundStyle(FloatingSurfaceTheme.costData()).font(FloatingSurfaceTypography.primaryMetric).tracking(-0.21).lineLimit(1).minimumScaleFactor(0.8)
                    heading(chart.note)
                }.frame(width: summaryWidth, alignment: .leading)
                DashboardRecentChartScroll(plotWidth: costPlotWidth, viewportWidth: costViewport, plotHeight: 58, resetID: generation) {
                    Canvas { context, size in
                        let track = GraphicsContext.Shading.color(FloatingSurfaceTheme.track())
                        let baseColor = FloatingSurfaceTheme.costData()
                        let stride = costCellSize + 3
                        let maxCost = chart.maximum
                        for (index, day) in chart.days.enumerated() {
                            let x = CGFloat(index) * stride
                            let barHeight = max(3, size.height * CGFloat((day.cost ?? 0) / maxCost))
                            let rect = CGRect(x: x, y: size.height - barHeight, width: costCellSize, height: barHeight)
                            let path = Path(roundedRect: rect, cornerRadius: 2)
                            if let cost = day.cost {
                                let highlighted = selectedCost == day.date || hoveredCost == day.date
                                let opacity = highlighted ? 1.0 : (0.35 + 0.4 * cost / maxCost)
                                context.fill(path, with: .color(baseColor.opacity(opacity)))
                            } else {
                                context.fill(path, with: track)
                            }
                        }
                    }
                    .frame(width: costPlotWidth, height: 58)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let next = costDayIndex(at: point, count: chart.days.count, cellWidth: costCellSize, height: 58)
                                .map { chart.days[$0].date }
                            if hoveredCost != next { hoveredCost = next }
                        case .ended:
                            if hoveredCost != nil { hoveredCost = nil }
                        }
                    }
                    .gesture(
                        SpatialTapGesture().onEnded { event in
                            if let index = costDayIndex(at: event.location, count: chart.days.count, cellWidth: costCellSize, height: 58) {
                                let date = chart.days[index].date
                                selectedCost = selectedCost == date ? nil : date
                            }
                        }
                    )
                    .overlay(alignment: .topLeading) {
                        if let hoveredCost, let index = chart.days.firstIndex(where: { $0.date == hoveredCost }) {
                            Color.clear
                                .frame(width: costCellSize, height: 58)
                                .offset(x: CGFloat(index) * (costCellSize + 3), y: 0)
                                .anchorPreference(key: DashboardHoverAnchor.self, value: .bounds) { $0 }
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(chart.title)
                    .accessibilityValue((chart.totalIsLowerBound && chart.total != nil ? "≥" : "") + money(chart.total))
                }
                .overlayPreferenceValue(DashboardHoverAnchor.self) { anchor in
                    if let day = chart.days.first(where: { $0.date == hoveredCost }) {
                        IslandUsageChartTooltip(anchor: anchor, height: 78) {
                            Text(Self.abbreviatedDateFormatter.string(from: day.date))
                            Text(day.cost == nil ? chart.missingLabel(for: day) : money(day.cost) + " · 估算值")
                            Text(tokens(day.tokens) + " Tokens")
                        }
                    }
                }.padding(.top, 8).zIndex(10)
                VStack(alignment: .trailing, spacing: 10) {
                    heading(selected?.date.formatted(.dateTime.month().day()) ?? chart.latestDateTag ?? "最近一天")
                    Text(money(selected != nil ? selected?.cost : chart.latest?.cost)).font(Font.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    heading("估算值 · 非账单")
                }.frame(width: summaryWidth, alignment: .trailing)
            }.fixedSize(horizontal: false, vertical: true)
        }
        .help(chart.helpText)
        .accessibilityHint(chart.accessibilityHint)
    }

    fileprivate static func monthTitle(for date: Date) -> String {
        monthFormatter.string(from: date)
    }

    fileprivate static func dateTitle(for date: Date) -> String {
        abbreviatedDateFormatter.string(from: date)
    }
}

private struct IslandUsageHeatmapCard: View, IslandUsageFormatting {
    let activity: [DailyTokenActivity]
    let lifetimeTokens: Int?
    let activityHelp: String
    let width: CGFloat
    let endingAt: Date
    let generation: String
    let countStyle: String
    @Binding var mode: IslandDashboardHeatmap.Mode
    @Binding var selectedActivity: String?
    @Binding var hoveredActivity: Int?

    private var contentWidth: CGFloat { width - 56 }
    private var activityPlotWidth: CGFloat { max(contentWidth - 28, 53 * 10 + 52 * 3) }
    private var cellSize: CGFloat { IslandDashboardHeatmap.cellSize(width: activityPlotWidth) }

    var body: some View {
        let grid = IslandDashboardHeatmap(
            activity: activity,
            endingAt: endingAt,
            mode: mode,
            lifetimeTokens: lifetimeTokens
        )
        IslandUsageHeatmapContentView(
            grid: grid,
            activityHelp: activityHelp,
            viewportWidth: contentWidth - 28,
            activityPlotWidth: activityPlotWidth,
            cellSize: cellSize,
            generation: generation,
            countStyle: countStyle,
            mode: $mode,
            selectedActivity: $selectedActivity,
            hoveredActivity: $hoveredActivity
        )
    }
}

private struct IslandUsageHeatmapContentView: View, IslandUsageFormatting {
    let grid: IslandDashboardHeatmap
    let activityHelp: String
    let viewportWidth: CGFloat
    let activityPlotWidth: CGFloat
    let cellSize: CGFloat
    let generation: String
    let countStyle: String
    @Binding var mode: IslandDashboardHeatmap.Mode
    @Binding var selectedActivity: String?
    @Binding var hoveredActivity: Int?

    private var rowsHeight: CGFloat { cellSize * 7 + 18 }

    private func cellHitIndex(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0, point.y <= rowsHeight else { return nil }
        let stride = cellSize + 3
        let column = Int(point.x / stride)
        let row = Int(point.y / stride)
        guard (0..<53).contains(column), (0..<7).contains(row),
              point.x - CGFloat(column) * stride <= cellSize + 1.5,
              point.y - CGFloat(row) * stride <= cellSize + 1.5 else { return nil }
        let index = grid.cellIndex(column: column, row: row)
        guard grid.cells.indices.contains(index), !grid.cells[index].future else { return nil }
        return index
    }

    var body: some View {
        let _ = countStyle
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                heading("Token 活动")
                if let selectedActivity { heading(selectedActivity).lineLimit(1) }
                Spacer(minLength: 8)
                ForEach(IslandDashboardHeatmap.Mode.allCases, id: \.self) { option in
                    Button { mode = option; selectedActivity = nil; hoveredActivity = nil } label: {
                        Text(option == .daily ? "每天" : option == .weekly ? "每周" : "累计")
                            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                            .islandGlass(Capsule(), tint: mode == option ? FloatingSurfaceTheme.accent().opacity(0.20) : .black.opacity(0.28))
                            .contentShape(Capsule())
                    }.buttonStyle(FloatingSurfaceButtonStyle()).accessibilityValue(mode == option ? "已选择" : "未选择")
                }
            }
            DashboardRecentChartScroll(
                plotWidth: activityPlotWidth,
                viewportWidth: viewportWidth,
                plotHeight: IslandDashboardHeatmap.chartHeight(width: activityPlotWidth),
                resetID: generation + "-\(mode)"
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Canvas { context, _ in
                        let track = GraphicsContext.Shading.color(FloatingSurfaceTheme.track())
                        let futureTrack = GraphicsContext.Shading.color(FloatingSurfaceTheme.track().opacity(0.25))
                        let base = FloatingSurfaceTheme.usageData()
                        let shade1 = GraphicsContext.Shading.color(base.opacity(0.25))
                        let shade2 = GraphicsContext.Shading.color(base.opacity(0.45))
                        let shade3 = GraphicsContext.Shading.color(base.opacity(0.65))
                        let shade4 = GraphicsContext.Shading.color(base.opacity(0.90))
                        let hoverStroke = GraphicsContext.Shading.color(base)
                        let stride = cellSize + 3
                        let maxVal = Double(max(1, grid.maximum))

                        for column in 0..<53 {
                            let x = CGFloat(column) * stride
                            for row in 0..<7 {
                                let index = grid.cellIndex(column: column, row: row)
                                let cell = grid.cells[index]
                                let y = CGFloat(row) * stride
                                let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                                let path = Path(roundedRect: rect, cornerRadius: 2)
                                if cell.future {
                                    context.fill(path, with: futureTrack)
                                    continue
                                }
                                let filled = grid.mode == .daily || grid.isFilled(column: column, row: row)
                                if filled, let value = cell.tokens, value > 0 {
                                    let level = Double(value) / maxVal
                                    let shading = level < 0.25 ? shade1 : (level < 0.5 ? shade2 : (level < 0.75 ? shade3 : shade4))
                                    context.fill(path, with: shading)
                                } else {
                                    context.fill(path, with: track)
                                }
                                if hoveredActivity == index {
                                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5), with: hoverStroke, lineWidth: 1)
                                }
                            }
                        }
                    }
                    .frame(width: activityPlotWidth, height: rowsHeight)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let next = cellHitIndex(at: point)
                            if hoveredActivity != next { hoveredActivity = next }
                        case .ended:
                            if hoveredActivity != nil { hoveredActivity = nil }
                        }
                    }
                    .gesture(
                        SpatialTapGesture().onEnded { event in
                            if let index = cellHitIndex(at: event.location) {
                                let cell = grid.cells[index]
                                selectedActivity = IslandUsageTrendCard.dateTitle(for: cell.date) + " · " + tokens(cell.tokens)
                            }
                        }
                    )
                    .overlay(alignment: .topLeading) {
                        if let index = hoveredActivity, grid.cells.indices.contains(index) {
                            let anchorColumn = grid.mode == .daily ? index / 7 : index
                            let anchorRow = grid.mode == .daily ? index % 7 : 0
                            Color.clear
                                .frame(width: cellSize, height: cellSize)
                                .offset(x: CGFloat(anchorColumn) * (cellSize + 3), y: CGFloat(anchorRow) * (cellSize + 3))
                                .anchorPreference(key: DashboardHoverAnchor.self, value: .bounds) { $0 }
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Token 活动热力图")
                    .accessibilityValue(selectedActivity ?? "峰值 " + tokens(grid.maximum))

                    ZStack(alignment: .leading) {
                        ForEach(grid.months.indices, id: \.self) { index in
                            Text(IslandUsageTrendCard.monthTitle(for: grid.months[index].date))
                                .font(FloatingSurfaceTypography.fine).foregroundStyle(secondary)
                                .offset(x: CGFloat(grid.months[index].column) * (cellSize + 3))
                        }
                    }.frame(width: activityPlotWidth, height: 12, alignment: .leading)
                }
            }
            .overlayPreferenceValue(DashboardHoverAnchor.self) { anchor in
                if let index = hoveredActivity, grid.cells.indices.contains(index) {
                    IslandUsageChartTooltip(anchor: anchor, height: 58) {
                        Text(IslandUsageTrendCard.dateTitle(for: grid.cells[index].date))
                        Text(tokens(grid.cells[index].tokens) + " Tokens")
                    }
                }
            }
        }
        .help(activityHelp)
    }
}

private struct IslandUsageChartTooltip<Content: View>: View {
    let anchor: Anchor<CGRect>?
    let height: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        // Resolve the upstream anchor outside the scroll clip so edge cells retain a readable tooltip.
        GeometryReader { proxy in
            if let anchor {
                let rect = proxy[anchor]
                let width = min(214, proxy.size.width)
                if rect.maxX > 0 && rect.minX < proxy.size.width {
                    VStack(alignment: .leading, spacing: 3, content: content)
                        .font(FloatingSurfaceTypography.caption).foregroundStyle(FloatingSurfaceTheme.primary()).padding(.horizontal, 11).padding(.vertical, 8)
                        .frame(width: width, alignment: .leading)
                        .background(FloatingSurfaceTheme.popover(), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(FloatingSurfaceTheme.outline(), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        .offset(x: min(max(0, rect.midX - width / 2), max(0, proxy.size.width - width)), y: rect.minY - height)
                }
            }
        }.allowsHitTesting(false)
    }
}
private struct DashboardHoverAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { if let next = nextValue() { value = next } }
}
