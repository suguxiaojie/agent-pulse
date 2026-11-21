import SwiftUI

private struct GlanceReadingHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum GlanceRefreshVisualState {
    case idle
    case refreshing
    case completed
}

private enum GlancePage {
    case summary
    case quotaReset
}

struct GlanceView: View {
    @AppStorage(CountStyle.preferenceKey) private var countStyle = CountStyle.chinese.rawValue
    @ObservedObject var store: MonitorStore
    @ObservedObject private var claude: ClaudeCodeRuntime
    @ObservedObject private var grok: GrokRuntime
    @ObservedObject private var antigravity: AntigravityRuntime
    @AppStorage("glance.provider") private var savedProvider = "codex"
    @State private var now = Date()
    let onQuit: () -> Void
    let onOpenCenter: (MonitorCenterSection) -> Void
    let onPreferredHeightChange: (CGFloat) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var readingHeight: CGFloat?
    @AppStorage("glance.stripMetric") private var stripMetric = "cost"
    @AppStorage(GlanceContentPreferenceKey.surfaceOpacity) private var surfaceOpacity = 0.38
    @State private var refreshVisualState: GlanceRefreshVisualState = .idle
    @State private var refreshRotation = 0.0
    @State private var refreshStartedAt = Date.distantPast
    @State private var page: GlancePage = .summary
    @State private var showsResetConfirmation = false
    @AppStorage(GlanceContentPreferenceKey.showPrimaryQuota) private var showPrimaryQuota = true
    @AppStorage(GlanceContentPreferenceKey.showCostEstimate) private var showCostEstimate = true
    @AppStorage(GlanceContentPreferenceKey.showCreditBalance) private var showCreditBalance = true
    @AppStorage(GlanceContentPreferenceKey.showDailyTokens) private var showDailyTokens = true
    @AppStorage(GlanceContentPreferenceKey.showThirtyDayTokens) private var showThirtyDayTokens = true
    @AppStorage(GlanceContentPreferenceKey.showTokenActivity) private var showTokenActivity = true
    @AppStorage(GlanceContentPreferenceKey.showResetEntry) private var showResetEntry = true

    init(store: MonitorStore, onQuit: @escaping () -> Void,
         onOpenCenter: @escaping (MonitorCenterSection) -> Void,
         onPreferredHeightChange: @escaping (CGFloat) -> Void) {
        self.store = store
        self.claude = store.claude
        self.grok = store.grok
        self.antigravity = store.antigravity
        self.onQuit = onQuit
        self.onOpenCenter = onOpenCenter
        self.onPreferredHeightChange = onPreferredHeightChange
    }

    private var provider: GlanceProvider {
        .resolve(savedProvider, claudeEnabled: claude.enabled, grokEnabled: grok.enabled, antigravityEnabled: antigravity.enabled)
    }
    private var availableProviders: [GlanceProvider] {
        [.codex]
            + (claude.enabled ? [.claude] : [])
            + (grok.enabled ? [.grok] : [])
            + (antigravity.enabled ? [.antigravity] : [])
    }
    private var usesTwoRowHeader: Bool {
        availableProviders.count > 1
    }
    private var effectiveHeaderHeight: CGFloat {
        usesTwoRowHeader ? 88 : GlanceLayout.headerHeight
    }
    private var claudeSnapshot: GlanceClaudeSnapshot {
        .init(limits: claude.limits, usage: claude.usage, statusLineEnabled: claude.statusLineEnabled, now: now)
    }
    private var quotaWindows: [RateLimitWindow] {
        provider == .claude ? claudeSnapshot.windows : primaryBucket?.windows ?? []
    }
    private var effectiveQuotaWindowCount: Int {
        switch provider {
        case .antigravity:
            return antigravity.statusLineEnabled ? (antigravity.quota?.activeWindows(at: now, staleCutoff: AntigravityQuotaSnapshot.uiStaleThreshold).count ?? 0) : 0
        case .grok:
            return 1
        case .codex, .claude:
            return quotaWindows.count
        }
    }

    var body: some View {
        Group {
            switch page {
            case .summary:
                summaryPage
            case .quotaReset:
                quotaResetPage
            }
        }
        .frame(width: GlanceLayout.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(primaryText)
        .background(alignment: .top) {
            if !reduceTransparency && contrast != .increased {
                let glowMultiplier: Double = {
                    switch provider {
                    case .claude:
                        return claudeSnapshot.glowMultiplier
                    case .antigravity:
                        return (antigravity.quota?.isStale(at: now, threshold: AntigravityQuotaSnapshot.uiStaleThreshold) ?? false) ? 0.5 : 1
                    case .grok:
                        let displayNow = GrokDisplayClock.now(sampled: now)
                        return (grok.quotaFailed || (grok.quota?.isStale(at: displayNow) ?? false)) ? 0.5 : 1
                    case .codex:
                        return 1
                    }
                }()
                RadialGradient(colors: [weatherColor.opacity((colorScheme == .dark ? 0.22 : 0.14) * glowMultiplier), .clear],
                               center: .top, startRadius: 0, endRadius: 250)
                    .frame(height: 300).blur(radius: 12)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: weatherTone)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: GlanceLayout.cornerRadius))
        .environment(\.glanceTextShadow, colorScheme == .dark && surfaceOpacity < 0.30 && !reduceTransparency && contrast != .increased)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: primaryRemaining)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .glanceKeyboardNavigate)) { note in
            guard page == .summary,
                  !store.isConsumingQuotaResetCredit,
                  !showsResetConfirmation,
                  availableProviders.count > 1,
                  let nav = note.object as? GlanceKeyboardNavigation else { return }
            let list = availableProviders
            let currentIdx = list.firstIndex(of: provider) ?? 0
            let targetIdx: Int
            switch nav {
            case .previous:
                targetIdx = (currentIdx - 1 + list.count) % list.count
            case .next:
                targetIdx = (currentIdx + 1) % list.count
            case .index(let idx):
                guard list.indices.contains(idx) else { return }
                targetIdx = idx
            }
            let nextProvider = list[targetIdx]
            guard nextProvider != provider else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                savedProvider = nextProvider.rawValue
            }
        }
        .onChange(of: claude.enabled) { enabled in
            if !enabled && savedProvider == GlanceProvider.claude.rawValue { savedProvider = GlanceProvider.codex.rawValue }
        }
        .onChange(of: grok.enabled) { enabled in
            if !enabled && savedProvider == GlanceProvider.grok.rawValue { savedProvider = GlanceProvider.codex.rawValue }
        }
        .onChange(of: grok.refreshing) { busy in
            if provider == .grok && !busy && refreshVisualState == .refreshing { finishManualRefresh() }
        }
        .onChange(of: antigravity.enabled) { enabled in
            if !enabled && savedProvider == GlanceProvider.antigravity.rawValue { savedProvider = GlanceProvider.codex.rawValue }
        }
        .onChange(of: antigravity.scanning) { busy in
            if provider == .antigravity && !busy && refreshVisualState == .refreshing { finishManualRefresh() }
        }
        .onChange(of: provider) { _ in
            page = .summary
            showsResetConfirmation = false
            refreshStartedAt = .distantPast
            refreshVisualState = .idle
            refreshRotation = 0
            now = Date()
        }
        .onChange(of: claude.usage?.updatedAt) { date in
            if provider == .claude, let date, date >= refreshStartedAt, refreshVisualState == .refreshing {
                finishManualRefresh()
            }
        }
        .onChange(of: store.costSnapshot.updatedAt) { updatedAt in
            completeRefreshIfReady(updatedAt: updatedAt)
        }
        .onChange(of: store.costSnapshot.costActivity.count) { _ in
            completeRefreshIfReady(updatedAt: store.costSnapshot.updatedAt)
        }
        .onPreferenceChange(GlanceReadingHeightKey.self) { height in
            guard case .summary = page, height.isFinite, height > 0 else { return }
            let next = ceil(height)
            if readingHeight.map({ abs($0 - next) > 0.5 }) ?? true { readingHeight = next }
        }
        .onAppear {
            savedProvider = provider.rawValue
            now = Date()
        }
        .task(id: preferredHeight) {
            let height = preferredHeight
            // Window resizing during the hosting view's layout can be overwritten by
            // the same AppKit pass. Deliver the latest measurement after that pass.
            await Task.yield()
            guard !Task.isCancelled else { return }
            onPreferredHeightChange(height)
        }
        .alert("确认重置额度？", isPresented: $showsResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("消耗 1 次并重置", role: .destructive) {
                store.consumeQuotaResetCredit()
            }
        } message: {
            Text(resetConfirmationMessage)
        }
        .accessibilityElement(children: .contain)
    }

    private var summaryPage: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: GlanceLayout.moduleSpacing) {
                        if provider == .grok {
                            GrokGlanceContent(
                                runtime: grok,
                                now: now,
                                showQuota: showPrimaryQuota,
                                showCost: showCostEstimate,
                                showActivity: showTokenActivity,
                                showDaily: showDailyTokens,
                                showMonth: showThirtyDayTokens,
                                metric: $stripMetric,
                                weatherColor: weatherColor,
                                showsInlinePlanBadge: !usesTwoRowHeader,
                                showCreditBalance: showCreditBalance
                            )
                        } else if provider == .antigravity {
                            AntigravityGlanceContent(
                                runtime: antigravity,
                                now: now,
                                weatherColor: weatherColor,
                                showsInlinePlanBadge: !usesTwoRowHeader,
                                showQuota: showPrimaryQuota,
                                showCost: showCostEstimate,
                                showCreditBalance: showCreditBalance,
                                showActivity: showTokenActivity,
                                showDaily: showDailyTokens,
                                showMonth: showThirtyDayTokens,
                                metric: $stripMetric,
                                onOpenCenter: { onOpenCenter(.antigravity) }
                            )
                        } else {
                        if showPrimaryQuota { primaryQuota }
                        if showCostEstimate || showTokenActivity { dayStrip }
                        if provider == .claude {
                            if showCostEstimate || showDailyTokens || showThirtyDayTokens { dataBlocks }
                        } else {
                            if showCreditBalance || showCostEstimate || showDailyTokens || showThirtyDayTokens { dataBlocks }
                        }
                        if provider == .codex && showResetEntry && !showPrimaryQuota {
                            resetCreditCard(store.quotaResetCredits).weatherModule()
                        }
                        }
                    }
                    .id(provider)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: provider)
                    .padding(.horizontal, GlanceLayout.contentInset)
                    .padding(.vertical, GlanceLayout.readingInset)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: GlanceReadingHeightKey.self, value: proxy.size.height)
                        }
                    }
                }
                .frame(height: max(0, geometry.size.height - effectiveHeaderHeight - GlanceLayout.footerHeight))
                .clipped()
                footer.padding(.horizontal, GlanceLayout.contentInset)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }

    private var quotaResetPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button {
                    withAnimation(reduceMotion ? nil : FloatingSurfaceTheme.selectionMotion) {
                        page = .summary
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(GlanceCircleButtonStyle())
                .help("返回额度概览")

                Text("额度重置")
                    .font(FloatingSurfaceTypography.title)
                    .tracking(-0.15)
                Spacer()
                Text("官方接口")
                    .font(FloatingSurfaceTypography.fineStrong)
                    .foregroundStyle(primaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .background(
                        FloatingSurfaceTheme.chipFill(colorScheme),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            .padding(.horizontal, GlanceLayout.contentInset)
            .frame(height: 50)


            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 7) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(store.quotaResetCredits.map { "\($0.availableCount)" } ?? "—")
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("可用重置次数")
                        .font(FloatingSurfaceTypography.section)
                        .foregroundStyle(secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

                VStack(spacing: 0) {
                    HStack {
                        Text("当前可用额度")
                        Spacer()
                        Text("\(primaryRemaining)%")
                            .font(FloatingSurfaceTypography.section)
                            .monospacedDigit()
                    }
                    .frame(height: 34)


                    HStack(spacing: 5) {
                        Image(systemName: "calendar.badge.clock")
                        Text(resetCreditExpirationText(store.quotaResetCredits))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 34)
                }
                .font(FloatingSurfaceTypography.label)
                .foregroundStyle(secondaryText)
                .weatherModule()

                VStack(alignment: .leading, spacing: 8) {
                    Label("重置前请确认", systemImage: "exclamationmark.triangle.fill")
                        .font(FloatingSurfaceTypography.section)
                        .foregroundStyle(.orange)
                    Text("• 此操作会消耗 1 次额度重置机会。")
                    Text("• 符合条件的 Codex 用量周期将立即重置。")
                    Text("• 额度重置完成后无法撤销。")
                }
                .font(FloatingSurfaceTypography.label)
                .foregroundStyle(secondaryText)
                .weatherModule()

                Spacer(minLength: 6)

                Button {
                    showsResetConfirmation = true
                } label: {
                    HStack(spacing: 6) {
                        if store.isConsumingQuotaResetCredit {
                            ProgressView()
                                .controlSize(.small)
                                .tint(FloatingSurfaceTheme.onDanger)
                        }
                        Text(store.isConsumingQuotaResetCredit ? "正在重置" : "重置额度")
                    }
                    .font(FloatingSurfaceTypography.captionStrong)
                    .foregroundStyle(FloatingSurfaceTheme.onDanger)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(
                        FloatingSurfaceTheme.danger.opacity(canConsumeResetCredit ? 0.30 : 0.12),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                FloatingSurfaceTheme.danger.opacity(canConsumeResetCredit ? 0.58 : 0.22),
                                lineWidth: 0.8
                            )
                    }
                }
                .buttonStyle(FloatingSurfaceButtonStyle())
                .disabled(!canConsumeResetCredit || store.isConsumingQuotaResetCredit)

                Text(store.quotaResetOperationMessage ?? resetOperationHint)
                    .font(FloatingSurfaceTypography.fine)
                    .foregroundStyle(
                        store.quotaResetOperationMessage == nil
                            ? tertiaryText
                            : secondaryText
                    )
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, GlanceLayout.contentInset)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity)

            footer
                .padding(.horizontal, GlanceLayout.contentInset)
        }
    }

    private var canConsumeResetCredit: Bool {
        (store.quotaResetCredits?.availableCount ?? 0) > 0
    }

    private var contentPreferences: GlanceContentPreferences {
        GlanceContentPreferences(
            showPrimaryQuota: showPrimaryQuota,
            showCostEstimate: showCostEstimate,
            showCreditBalance: showCreditBalance,
            showDailyTokens: showDailyTokens,
            showThirtyDayTokens: showThirtyDayTokens,
            showTokenActivity: showTokenActivity,
            showResetEntry: showResetEntry,
            surfaceOpacity: UserDefaults.standard.object(
                forKey: GlanceContentPreferenceKey.surfaceOpacity
            ) as? Double ?? GlanceContentPreferences.defaults.surfaceOpacity
        )
    }

    private var preferredHeight: CGFloat {
        switch page {
        case .summary:
            let extraHeader = effectiveHeaderHeight - GlanceLayout.headerHeight
            let base = GlanceLayout.preferredHeight(
                readingHeight: readingHeight,
                estimatedHeight: contentPreferences.preferredHeight(
                    primaryQuotaWindowCount: effectiveQuotaWindowCount,
                    provider: provider
                )
            )
            return min(GlanceLayout.height, base + extraHeader)
        case .quotaReset:
            return GlanceLayout.resetPageHeight
        }
    }

    private var resetOperationHint: String {
        canConsumeResetCredit
            ? "确认后将通过官方接口消耗 1 次额度重置机会。"
            : "当前没有可用额度卡，无法执行重置。"
    }

    private var resetConfirmationMessage: String {
        "此操作将消耗 1 次额度重置机会，并立即重置符合条件的 Codex 用量周期。操作完成后无法撤销。\n\n\(resetCreditExpirationText(store.quotaResetCredits))"
    }

    @ViewBuilder
    private var header: some View {
        if usesTwoRowHeader {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    CodexMark(size: 20)
                    Text("Agent Pulse").font(.system(size: 13, weight: .semibold)).fixedSize()
                    Spacer(minLength: 6)
                    headerContextBadge
                }
                GlanceProviderSwitch(
                    selection: Binding(get: { provider }, set: { savedProvider = $0.rawValue }),
                    available: availableProviders,
                    fullWidth: true,
                    activeColor: weatherColor,
                    providerTones: providerTones,
                    providerRemaining: providerRemainingPercents
                )
                .disabled(store.isConsumingQuotaResetCredit || showsResetConfirmation)
            }
            .padding(.horizontal, GlanceLayout.contentInset)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(height: effectiveHeaderHeight)
        } else {
            HStack(spacing: 6) {
                CodexMark(size: 20)
                Text("Agent Pulse").font(.system(size: 13, weight: .semibold)).fixedSize()
                Spacer(minLength: 0)
                if availableProviders.count > 1 {
                    GlanceProviderSwitch(
                        selection: Binding(get: { provider }, set: { savedProvider = $0.rawValue }),
                        available: availableProviders,
                        activeColor: weatherColor,
                        providerTones: providerTones
                    )
                    .disabled(store.isConsumingQuotaResetCredit || showsResetConfirmation)
                } else {
                    accountBadge
                }
            }
            .padding(.horizontal, GlanceLayout.contentInset)
            .frame(height: GlanceLayout.headerHeight)
        }
    }

    @ViewBuilder
    private var headerContextBadge: some View {
        switch provider {
        case .codex:
            accountBadge
        case .antigravity:
            if antigravity.statusLineEnabled, let plan = antigravity.quota?.resolvedPlan {
                let stale = antigravity.quota?.isStale(at: now, threshold: AntigravityQuotaSnapshot.uiStaleThreshold) ?? false
                statusChipBadge(title: plan, color: stale ? Color.orange.opacity(0.88) : Color.green.opacity(0.90))
            }
        case .grok:
            if let plan = grok.quota?.plan {
                statusChipBadge(
                    title: plan,
                    color: grok.quotaFailed ? Color.orange.opacity(0.88) : Color.green.opacity(0.90)
                )
            }
        case .claude:
            if claude.statusLineEnabled {
                let missing = claudeSnapshot.windows.isEmpty && !claudeSnapshot.rolledOverFiveHour
                statusChipBadge(
                    title: missing ? "等待状态栏" : "Claude Code",
                    color: (claudeSnapshot.isStale || missing) ? Color.orange.opacity(0.88) : Color.green.opacity(0.90)
                )
            } else {
                statusChipBadge(title: "仅本地日志", color: Color.orange.opacity(0.88))
            }
        }
    }

    private func statusChipBadge(title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(FloatingSurfaceTheme.chipFill(colorScheme), in: Capsule())
        .help(title)
    }

    private var accountBadge: some View {
        statusChipBadge(title: currentAccountBadgeTitle, color: currentAccountIndicatorColor)
    }

    private func tone(for target: GlanceProvider) -> GlanceTone {
        switch target {
        case .codex:
            guard let window = primaryBucket?.limitingWindow else { return .calm }
            return GlanceTone(window: window, forecast: QuotaPaceForecast(window: window, now: now))
        case .claude:
            guard let window = claudeSnapshot.limitingWindow else { return .calm }
            return GlanceTone(window: window, forecast: QuotaPaceForecast(window: window, now: now))
        case .grok:
            let displayNow = GrokDisplayClock.now(sampled: now)
            guard let quota = grok.quota, quota.isAvailable(at: displayNow) else { return .calm }
            let durationMinutes: Int? = {
                if let start = quota.startsAt, let end = quota.resetsAt, end > start {
                    return max(1, Int(end.timeIntervalSince(start) / 60))
                }
                if quota.periodType == "USAGE_PERIOD_TYPE_WEEKLY" { return 10_080 }
                if quota.periodType == "USAGE_PERIOD_TYPE_MONTHLY" { return 43_200 }
                return nil
            }()
            let rl = RateLimitWindow(usedPercent: Int(quota.usedPercent.rounded()), windowDurationMinutes: durationMinutes, resetsAt: quota.resetsAt)
            return GlanceTone(window: rl, forecast: QuotaPaceForecast(window: rl, now: displayNow))
        case .antigravity:
            let active = antigravity.statusLineEnabled ? (antigravity.quota?.activeWindows(at: now, staleCutoff: AntigravityQuotaSnapshot.uiStaleThreshold) ?? []) : []
            guard let limiting = active.min(by: { $0.remainingPercent < $1.remainingPercent }) else { return .calm }
            let rl = RateLimitWindow(usedPercent: Int(limiting.usedPercent.rounded()), windowDurationMinutes: limiting.durationMinutes, resetsAt: limiting.resetsAt)
            return GlanceTone(window: rl, forecast: QuotaPaceForecast(window: rl, now: now))
        }
    }

    private var providerTones: [GlanceProvider: GlanceTone] {
        var map: [GlanceProvider: GlanceTone] = [:]
        for item in availableProviders {
            map[item] = tone(for: item)
        }
        return map
    }

    private func remainingPercent(for target: GlanceProvider) -> Int? {
        switch target {
        case .codex:
            return primaryBucket?.limitingWindow?.remainingPercent
        case .claude:
            if let limiting = claudeSnapshot.limitingWindow {
                return limiting.remainingPercent
            }
            return claudeSnapshot.rolledOverFiveHour ? 100 : nil
        case .grok:
            let displayNow = GrokDisplayClock.now(sampled: now)
            guard let quota = grok.quota, quota.isAvailable(at: displayNow) else { return nil }
            return quota.remainingPercent
        case .antigravity:
            guard antigravity.statusLineEnabled else { return nil }
            let active = antigravity.quota?.activeWindows(at: now, staleCutoff: AntigravityQuotaSnapshot.uiStaleThreshold) ?? []
            if let limiting = active.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                return limiting.remainingPercent
            }
            if antigravity.quota?.rolledOverGeminiFiveHour(at: now, staleCutoff: AntigravityQuotaSnapshot.uiStaleThreshold) != nil {
                return 100
            }
            return nil
        }
    }

    private var providerRemainingPercents: [GlanceProvider: Int?] {
        var map: [GlanceProvider: Int?] = [:]
        for item in availableProviders {
            map[item] = remainingPercent(for: item)
        }
        return map
    }

    private var weatherTone: GlanceTone { tone(for: provider) }

    private var weatherColor: Color { weatherTone.color }

    private var primaryQuota: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let window = primaryWindow {
                let forecast = QuotaPaceForecast(window: window, now: context.date)
                let copy = forecast.copy(resetsAt: window.resetsAt, now: context.date)
                let otherWindows = quotaWindows.filter { $0 != window }
                let secondaryWindow = otherWindows.first
                let secondaryPercent: Int? = {
                    if let sec = secondaryWindow { return sec.remainingPercent }
                    if provider == .claude && claudeSnapshot.rolledOverFiveHour { return 100 }
                    return nil
                }()
                let showsInlineReset = provider == .codex && showResetEntry
                let footerLeftText: String? = {
                    if let sec = secondaryWindow {
                        return showsInlineReset
                            ? "\(compactWindowTitle(sec)) \(sec.remainingPercent)%"
                            : "\(compactWindowTitle(sec)) \(sec.remainingPercent)%"
                    }
                    if provider == .claude && claudeSnapshot.rolledOverFiveHour {
                        return "5 小时额度 100%"
                    }
                    return provider == .claude ? "Claude 官方状态栏同步" : "官方配额实时同步"
                }()
                let footerRightText: String? = {
                    if showsInlineReset { return nil }
                    if let sec = secondaryWindow {
                        return resetText(sec)
                    }
                    if provider == .claude && claudeSnapshot.rolledOverFiveHour {
                        return "已重置（待同步）"
                    }
                    return nil
                }()

                GlanceHeroQuotaCard(
                    title: compactWindowTitle(window),
                    remainingPercent: window.remainingPercent,
                    primaryCopy: copy.primary,
                    secondaryCopy: copy.secondary + (provider == .claude ? claudeSnapshot.observationSuffix() : ""),
                    weatherColor: weatherColor,
                    secondaryRingPercent: secondaryPercent,
                    footerLeft: footerLeftText,
                    footerRight: footerRightText,
                    isStale: provider == .claude && claudeSnapshot.isStale
                ) {
                    if provider == .codex && !usesTwoRowHeader && availableProviders.count > 1 {
                        accountBadge
                    }
                } footerTrailing: {
                    if showsInlineReset {
                        inlineResetButton(store.quotaResetCredits)
                    }
                }
            } else if provider == .claude && claudeSnapshot.rolledOverFiveHour {
                GlanceHeroQuotaCard(
                    title: "5 小时额度",
                    remainingPercent: 100,
                    primaryCopy: "当前 5 小时周期已重置",
                    secondaryCopy: "待下次 Claude 回复同步新周期重置时间",
                    weatherColor: weatherColor,
                    footerLeft: "Claude 官方状态栏同步"
                ) {
                    EmptyView()
                }
            } else if provider == .claude {
                GlanceEmptyQuotaCard(
                    title: "Claude 额度",
                    message: claudeSnapshot.quotaPlaceholder ?? "等待 Claude Code 下一次回复后同步额度"
                ) {
                    EmptyView()
                } action: {
                    if !claude.statusLineEnabled {
                        Button("打开 Claude 设置") { onOpenCenter(.claude) }
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(weatherColor)
                            .buttonStyle(FloatingSurfaceButtonStyle())
                    }
                }
            } else {
                GlanceEmptyQuotaCard(
                    title: "Codex 额度",
                    message: footerUpdateText == "数据可能过期" ? "额度加载失败" : "正在同步额度窗口…"
                ) {
                    if !usesTwoRowHeader && availableProviders.count > 1 {
                        accountBadge
                    }
                } action: {
                    if showResetEntry {
                        inlineResetButton(store.quotaResetCredits)
                    }
                }
            }
        }
    }

    private func inlineResetButton(_ summary: QuotaResetCreditSummary?) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : FloatingSurfaceTheme.selectionMotion) {
                page = .quotaReset
            }
        } label: {
            HStack(spacing: 3) {
                Text(summary.map { $0.availableCount > 0 ? "重置 \($0.availableCount) 次可用" : "额度重置" } ?? "额度重置")
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(weatherColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(FloatingSurfaceButtonStyle())
        .accessibilityLabel(
            "额度重置，\(summary.map { ChineseDisplayText.count($0.availableCount, unit: "次可用") } ?? "可用次数未知")，\(resetCreditExpirationText(summary))"
        )
        .accessibilityHint("打开额度重置确认页面")
    }

    private var usesCostStrip: Bool { showCostEstimate && (!showTokenActivity || stripMetric != "token") }

    private var dayStrip: some View {
        let snapshot = claudeSnapshot
        let entries = provider == .claude
            ? (usesCostStrip ? snapshot.costSamples : snapshot.tokenSamples)
            : (usesCostStrip
                ? selectedCostScope.costActivity.map { GlanceDayStrip.Sample(date: $0.date, value: $0.dollars) }
                : selectedCostScope.usage.activity.map { GlanceDayStrip.Sample(date: $0.date, value: Double($0.tokens)) })
        let codexReady = hasCurrentAccountHistory && selectedCostScope.usage.activityIsReady
        let codexLoadingMessage: String = {
            if !hasCurrentAccountHistory {
                return currentAccount == nil ? "正在识别当前 Codex 账号…" : "当前账号暂无已归属本地用量"
            }
            return "用量明细尚未就绪"
        }()
        return GlanceWeatherStrip(buckets: GlanceDayStrip.buckets(samples: entries, now: now),
            isCost: usesCostStrip, isReady: provider == .claude ? snapshot.usageReady : codexReady,
            showsSelector: showCostEstimate && showTokenActivity, metric: $stripMetric, color: weatherColor,
            unknownModels: provider == .claude ? [] : selectedCostScope.unknownModels,
            loadingText: provider == .claude ? "正在统计 Claude 用量…" : codexLoadingMessage,
            tokenSourceLabel: provider == .claude ? "本机 Claude 用量" : "当前账号本地用量",
            unpricedDates: provider == .claude ? snapshot.unpricedDates : [])
    }

    private var dataBlocks: some View {
        HStack(spacing: 6) {
            if provider == .claude {
                let ready = claudeSnapshot.usageReady
                if showCostEstimate {
                    dataBlock("今日成本", value: ready ? GlanceDayStrip.metricCardCostText(claudeSnapshot.todayCost) : "—")
                }
                if showDailyTokens { dataBlock("今日 Token", value: ready ? GlanceDayStrip.tokenText(Double(claudeSnapshot.todayTokens)) : "—") }
                if showThirtyDayTokens { dataBlock("30 日 Token", value: ready ? GlanceDayStrip.tokenText(Double(claudeSnapshot.monthlyTokens)) : "—") }
                if !showCostEstimate && !showDailyTokens && !showThirtyDayTokens {
                    dataBlock("累计 Token", value: ready ? (claudeSnapshot.lifetimeTokens.map { GlanceDayStrip.tokenText(Double($0)) } ?? "—") : "—")
                }
            } else {
                let ready = hasCurrentAccountHistory
                if showCreditBalance {
                    dataBlock("Credits", value: CreditBalanceFormatter.summary(primaryBucket?.creditBalance))
                        .help("完整余额：" + CreditBalanceFormatter.string(primaryBucket?.creditBalance))
                        .accessibilityValue(CreditBalanceFormatter.string(primaryBucket?.creditBalance))
                } else if showCostEstimate {
                    dataBlock("今日成本", value: ready ? GlanceDayStrip.metricCardCostText(selectedCostScope.today.dollars) : "—")
                }
                if showDailyTokens { dataBlock("今日 Token", value: ready ? compactTokens(selectedCostScope.usage.day.tokens) : "—") }
                if showThirtyDayTokens { dataBlock("30 日 Token", value: ready ? compactTokens(selectedCostScope.usage.month.tokens) : "—") }
            }
        }
    }

    private func dataBlock(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9)).foregroundStyle(secondaryText)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).glanceReadableText()
        }.frame(maxWidth: .infinity, alignment: .leading).weatherModule()
            .accessibilityElement(children: .combine)
    }

    private func compactWindowTitle(_ window: RateLimitWindow) -> String {
        switch window.kind {
        case .fiveHour: return "5 小时额度"
        case .weekly: return "每周额度"
        case .custom, .unknown: return window.windowLabel
        }
    }


    private var currentAccountHistoryEmptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: store.isCostLoading ? "arrow.triangle.2.circlepath" : "tray")
                    .foregroundStyle(secondaryText)
                Text(store.isCostLoading ? "正在读取当前账号用量…" : "当前账号暂无本地用量记录")
                    .font(FloatingSurfaceTypography.section)
                    .foregroundStyle(primaryText)
            }
            Text(store.isCostLoading ? "正在整理已观察到的账号日志。" : "尚未识别到归属该账号的 Cost 或 Token 数据。")
                .font(FloatingSurfaceTypography.fine)
                .foregroundStyle(tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            FloatingSurfaceTheme.rowFill(colorScheme),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.vertical, 8)
    }

    private var targetCenterSection: MonitorCenterSection {
        switch provider {
        case .codex: return .usage
        case .claude: return .claude
        case .grok: return .grok
        case .antigravity: return .antigravity
        }
    }

    private var centerButtonHelp: String {
        switch provider {
        case .codex: return "打开监控中心"
        case .claude: return "打开 Claude 监控专页"
        case .grok: return "打开 Grok 监控专页"
        case .antigravity: return "打开 Antigravity 监控专页"
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Circle().fill(footerStatusColor).frame(width: 5, height: 5)
            Text(footerUpdateText).font(.system(size: 9)).foregroundStyle(secondaryText).lineLimit(1)
            Spacer(minLength: 0)
            refreshFooterButton
            footerButton(symbol: "chart.bar", help: centerButtonHelp) { onOpenCenter(targetCenterSection) }
            footerButton(symbol: "gearshape", help: "打开面板设置") { onOpenCenter(.panelSettings) }
            footerButton(symbol: "power", help: "退出 Agent Pulse", action: onQuit)
        }.frame(height: GlanceLayout.footerHeight)
    }

    private func resetCreditCard(_ summary: QuotaResetCreditSummary?) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : FloatingSurfaceTheme.selectionMotion) {
                page = .quotaReset
            }
        } label: {
            resetCreditCardContent(summary)
        }
        .buttonStyle(FloatingSurfaceButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "额度重置，\(summary.map { ChineseDisplayText.count($0.availableCount, unit: "次可用") } ?? "可用次数未知")，\(resetCreditExpirationText(summary))"
        )
        .accessibilityHint("打开额度重置确认页面")
    }

    private func resetCreditCardContent(_ summary: QuotaResetCreditSummary?) -> some View {
        HStack(spacing: 6) {
            Text("额度重置").foregroundStyle(primaryText)
            Spacer(minLength: 0)
            Text(summary.map { $0.availableCount > 0 ? "\($0.availableCount) 次可使用" : resetCreditExpirationText(summary) } ?? "数据未知")
                .foregroundStyle(weatherColor).lineLimit(1).minimumScaleFactor(0.7)
            Image(systemName: "chevron.right").foregroundStyle(weatherColor)
        }.font(.system(size: 11, weight: .medium)).contentShape(Rectangle())
    }

    private func resetCreditExpirationText(_ summary: QuotaResetCreditSummary?) -> String {
        let now = Date()
        guard let expiration = summary?.nearestExpiration(relativeTo: now) else {
            return "有效期未知"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d HH:mm"
        let value = formatter.string(from: expiration)
        return expiration > now
            ? "有效期至 \(value)"
            : "已于 \(value) 过期"
    }

    private func footerButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(GlanceCircleButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private var refreshFooterButton: some View {
        Button(action: beginManualRefresh) {
            Image(
                systemName: refreshVisualState == .completed
                    ? "checkmark"
                    : "arrow.clockwise"
            )
            .rotationEffect(
                .degrees(refreshVisualState == .refreshing ? refreshRotation : 0)
            )
            .scaleEffect(refreshVisualState == .completed ? 1.08 : 1)
        }
        .buttonStyle(GlanceCircleButtonStyle())
        .disabled(refreshVisualState == .refreshing)
        .help(
            refreshVisualState == .refreshing
                ? "正在刷新"
                : (refreshVisualState == .completed ? "刷新完成" : "刷新全部数据")
        )
        .accessibilityLabel(
            refreshVisualState == .refreshing
                ? "正在刷新"
                : (refreshVisualState == .completed ? "刷新完成" : "刷新全部数据")
        )
    }

    private func beginManualRefresh() {
        guard refreshVisualState != .refreshing else { return }
        refreshStartedAt = Date()
        refreshVisualState = .refreshing
        refreshRotation = 0
        if !reduceMotion {
            withAnimation(.linear(duration: 0.72).repeatForever(autoreverses: false)) {
                refreshRotation = 360
            }
        }
        if provider == .grok { grok.refresh() }
        else if provider == .antigravity { antigravity.refresh() }
        else if provider == .claude { claude.refreshUsage() }
        else { store.refreshAll() }

        let startedAt = refreshStartedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard refreshVisualState == .refreshing,
                  refreshStartedAt == startedAt
            else { return }
            finishManualRefresh()
        }
    }

    private func completeRefreshIfReady(updatedAt: Date) {
        guard provider == .codex, refreshVisualState == .refreshing,
              updatedAt >= refreshStartedAt,
              !store.costSnapshot.costActivity.isEmpty
        else { return }
        finishManualRefresh()
    }

    private func finishManualRefresh() {
        withAnimation(reduceMotion ? nil : FloatingSurfaceTheme.pressMotion) {
            refreshRotation = 0
            refreshVisualState = .completed
        }
        let completedAt = refreshStartedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard refreshVisualState == .completed,
                  refreshStartedAt == completedAt
            else { return }
            withAnimation(reduceMotion ? nil : FloatingSurfaceTheme.selectionMotion) {
                refreshVisualState = .idle
            }
        }
    }

    private var primaryBucket: RateLimitBucket? {
        store.quotaState.primaryBucket
    }

    private var currentAccount: UsageAccountOption? {
        guard let id = UsageAccountSelection.currentAccountID(
            in: store.usageAccountOptions
        ) else { return nil }
        return store.usageAccountOptions.first { $0.id == id }
    }

    private var selectedCostScope: CostScopeSnapshot {
        guard let currentAccount else { return .empty }
        return store.costSnapshot.scope(for: currentAccount.id)
    }

    private var currentAccountBadgeTitle: String {
        let alias = currentAccount?.alias ?? store.continuityAccountTitle
        let plan = OpenAIPlanDisplayName.resolve(primaryBucket?.planType)
        return [alias, plan].compactMap { $0 }.joined(separator: " · ")
    }

    private var primaryWindow: RateLimitWindow? {
        if provider == .grok || provider == .antigravity { return nil }
        return provider == .claude ? claudeSnapshot.limitingWindow : primaryBucket?.limitingWindow
    }

    private var currentAccountIndicatorColor: Color {
        switch store.quotaState {
        case .loaded: return Color.green.opacity(0.90)
        case .loading: return FloatingSurfaceTheme.accent(colorScheme).opacity(0.82)
        case .failed: return Color.orange.opacity(0.88)
        }
    }

    private var hasCurrentAccountHistory: Bool {
        selectedCostScope.month.tokens > 0
            || selectedCostScope.month.dollars > 0
            || selectedCostScope.usage.month.sessionCount > 0
    }

    private var primaryRemaining: Int {
        primaryWindow?.remainingPercent ?? 0
    }

    private var footerUpdateText: String {
        if provider == .grok { return grok.refreshing ? "正在查询" : grok.quotaStatus }
        if provider == .antigravity {
            if antigravity.scanning { return "正在刷新" }
            let latest = [antigravity.statusLineEnabled ? antigravity.quota?.capturedAt : nil, antigravity.usage?.updatedAt].compactMap { $0 }.max()
            guard let date = latest else { return "等待数据" }
            if now.timeIntervalSince(date) < 60 { return "刚刚更新" }
            return "更新于 " + date.formatted(.dateTime.hour().minute())
        }
        if provider == .claude {
            guard let date = claudeSnapshot.updatedAt else { return "等待数据" }
            if now.timeIntervalSince(date) < 60 { return "刚刚更新" }
            return "更新于 " + date.formatted(.dateTime.hour().minute())
        }
        switch store.quotaState {
        case .loading:
            return "正在更新"
        case let .loaded(_, date):
            if Date().timeIntervalSince(date) < 60 { return "刚刚更新" }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "更新于 \(formatter.string(from: date))"
        case .failed:
            return "数据可能过期"
        }
    }

    private var footerStatusColor: Color {
        if provider == .grok { return grok.quotaFailed || grok.quota == nil ? .orange : .green }
        if provider == .antigravity {
            let active = antigravity.statusLineEnabled ? (antigravity.quota?.activeWindows(at: now, staleCutoff: AntigravityQuotaSnapshot.uiStaleThreshold) ?? []) : []
            let stale = antigravity.quota?.isStale(at: now, threshold: AntigravityQuotaSnapshot.uiStaleThreshold) ?? false
            return antigravity.usage == nil || stale || (antigravity.statusLineEnabled && active.isEmpty) ? .orange : .green
        }
        if provider == .claude {
            return claudeSnapshot.updatedAt == nil || claudeSnapshot.isStale || !claudeSnapshot.usageReady ? .orange : .green
        }
        switch store.quotaState {
        case .loaded: return .green
        case .loading: return .orange
        case .failed: return .red
        }
    }

    private func resetText(_ window: RateLimitWindow?) -> String {
        guard let date = window?.resetsAt else { return "重置时间未知" }
        return ChineseDisplayText.spacing(QuotaResetCountdown.text(until: date, relativeTo: Date()))
    }

    private func compactTokens(_ value: Int) -> String {
        CountFormatter.display(Int64(value))
    }

    private var primaryText: Color {
        FloatingSurfaceTheme.primary(colorScheme)
    }

    private var secondaryText: Color {
        FloatingSurfaceTheme.detail(colorScheme)
    }

    private var tertiaryText: Color {
        FloatingSurfaceTheme.secondary(colorScheme)
    }

}

private struct GlanceCircleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(enabled && (hovered || configuration.isPressed) ? FloatingSurfaceTheme.accent(colorScheme) : FloatingSurfaceTheme.secondary(colorScheme))
            .frame(width: 28, height: 28)
            .background(FloatingSurfaceTheme.accent(colorScheme).opacity(enabled && configuration.isPressed ? 0.18 : enabled && hovered ? 0.12 : 0.055), in: Circle())
            .overlay(Circle().strokeBorder(enabled && focused ? FloatingSurfaceTheme.accent(colorScheme) : .clear, lineWidth: 1.5))
            .contentShape(Circle()).opacity(enabled ? 1 : 0.45)
            .scaleEffect(enabled && configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : FloatingSurfaceTheme.hoverMotion, value: hovered)
            .animation(reduceMotion ? nil : FloatingSurfaceTheme.pressMotion, value: configuration.isPressed)
    }
}
