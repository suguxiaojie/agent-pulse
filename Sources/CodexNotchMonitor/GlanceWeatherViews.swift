import SwiftUI

extension GlanceTone {
    var color: Color {
        switch self {
        case .calm: return Color(red: 63 / 255, green: 181 / 255, blue: 201 / 255)
        case .tight: return .orange
        case .critical: return .red
        }
    }
}

private struct GlanceTextShadowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var glanceTextShadow: Bool {
        get { self[GlanceTextShadowKey.self] }
        set { self[GlanceTextShadowKey.self] = newValue }
    }
}
private struct GlanceReadableText: ViewModifier {
    @Environment(\.glanceTextShadow) private var enabled
    func body(content: Content) -> some View {
        content.shadow(color: enabled ? .black.opacity(0.35) : .clear, radius: 1.5)
    }
}
extension View {
    func glanceReadableText() -> some View { modifier(GlanceReadableText()) }
    func weatherModule() -> some View {
        padding(10)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5).padding(.horizontal, 16)
                    .accessibilityHidden(true)
            }
    }
}

struct GlanceWeatherStrip: View {
    @AppStorage(CountStyle.preferenceKey) private var countStyle = CountStyle.chinese.rawValue
    let buckets: [GlanceDayStrip.Bucket]
    let isCost: Bool
    let isReady: Bool
    let showsSelector: Bool
    @Binding var metric: String
    let color: Color
    let unknownModels: [String]
    var loadingText = "用量明细尚未就绪"
    var tokenSourceLabel = "当前账号本地用量"
    var unpricedDates: Set<Date> = []
    var unpricedHelpText: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: Date?
    @State private var hoverClearWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                GlanceMetricTabs(selection: Binding(
                    get: { selectedMetric }, set: { metric = $0.rawValue }
                ), showsSelector: showsSelector)
                Spacer(minLength: 0)
                Text(isReady ? totalText : "—")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
            HStack(spacing: 4) {
                Text(selectedMetric.subtitle(tokenSourceLabel: tokenSourceLabel))
                    .font(.system(size: 9)).foregroundStyle(FloatingSurfaceTheme.secondary(colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isCost && (!unknownModels.isEmpty || !unpricedDates.isEmpty) {
                    Text("部分模型未计价")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(unpricedHelpText ?? (unpricedDates.isEmpty
                              ? "当前账号日志包含未计价模型：" + unknownModels.joined(separator: "、") + "。该提示不限定于最近 7 天。"
                              : "Claude 用量包含未计价日期；现有快照未提供这些日期的已知部分金额。"))
                }
            }
            if isReady {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(buckets) { bucket in
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottom) {
                                if isCost && unpricedDates.contains(bucket.date) {
                                    Capsule()
                                        .fill(color.opacity(0.08))
                                        .frame(width: 10, height: 30)
                                        .overlay {
                                            Capsule()
                                                .strokeBorder(color.opacity(0.58), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                                        }
                                } else {
                                    Capsule().fill(color.opacity(0.08)).frame(width: 10)
                                    Capsule().fill(color.opacity(bucket.value > 0 && bucket.value == maximumValue ? 1 : 0.38))
                                        .frame(width: 10, height: bucket.value > 0 ? max(2, 44 * bucket.value / max(1, maximumValue)) : 0)
                                }
                            }.frame(height: 44)
                            Text(bucket.label)
                                .font(.system(size: 9.5, weight: bucket.label == "今" ? .semibold : .regular))
                                .foregroundStyle(bucket.label == "今" ? FloatingSurfaceTheme.primary(colorScheme) : FloatingSurfaceTheme.secondary(colorScheme))
                        }
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                        .onHover { hovering in updateHover(bucket.date, hovering: hovering) }
                        .help(detail(bucket))
                        .accessibilityElement(children: .ignore).accessibilityLabel(detail(bucket))
                    }
                }
                Text(buckets.first(where: { $0.date == hovered }).map(detail) ?? summary)
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(FloatingSurfaceTheme.detail(colorScheme))
            } else {
                Text(loadingText)
                    .font(.system(size: 10))
                    .foregroundStyle(FloatingSurfaceTheme.detail(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 75)
            }
        }.weatherModule()
            .frame(height: 136)
            .onDisappear { hoverClearWorkItem?.cancel() }
    }

    private var maximumValue: Double {
        buckets.filter { !isCost || !unpricedDates.contains($0.date) }.map(\.value).max() ?? 0
    }

    private var selectedMetric: GlanceStripMetric { isCost ? .cost : .token }

    private var totalText: String {
        isCost ? GlanceDayStrip.costTotalText(buckets, unpricedDates: unpricedDates)
            : CountFormatter.chart(buckets.reduce(0) { $0 + $1.value }, style: CountStyle(rawValue: countStyle) ?? .chinese)
    }

    private func updateHover(_ date: Date, hovering: Bool) {
        hoverClearWorkItem?.cancel()
        if hovering { hovered = date; return }
        let work = DispatchWorkItem { if hovered == date { hovered = nil } }
        hoverClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private var summary: String {
        isCost ? GlanceDayStrip.costSummaryText(buckets, unpricedDates: unpricedDates)
            : GlanceDayStrip.summaryText(buckets, formatValue: GlanceDayStrip.tokenText)
    }

    private func detail(_ bucket: GlanceDayStrip.Bucket) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let value = isCost ? GlanceDayStrip.costDetailValue(bucket, unpricedDates: unpricedDates) : CountFormatter.chart(bucket.value) + " Token"
        return "\(formatter.string(from: bucket.date)) · \(value)"
    }
}

struct GlanceProviderSwitch: View {
    @Binding var selection: GlanceProvider
    var available: [GlanceProvider] = [.codex, .claude]
    var fullWidth: Bool = false
    var activeColor: Color? = nil
    var providerTones: [GlanceProvider: GlanceTone] = [:]
    var providerRemaining: [GlanceProvider: Int?] = [:]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    private func label(for provider: GlanceProvider, compact: Bool) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .antigravity: return compact ? "AGY" : "Antigravity"
        }
    }

    private func accessibilityName(for provider: GlanceProvider) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok CLI"
        case .antigravity: return "Antigravity"
        }
    }

    private func brand(for provider: GlanceProvider) -> ProviderBrandIcon.Brand {
        switch provider {
        case .codex: return .codex
        case .claude: return .claude
        case .grok: return .grok
        case .antigravity: return .antigravity
        }
    }

    private var switchWidth: CGFloat {
        available.contains(.antigravity) ? 156 : 138
    }

    var body: some View {
        let resolvedHighlight = activeColor ?? FloatingSurfaceTheme.accent(colorScheme)
        if fullWidth {
            telemetryTiles(resolvedHighlight: resolvedHighlight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("用量来源")
        } else {
            compactPills(resolvedHighlight: resolvedHighlight)
                .frame(width: switchWidth, height: 28)
                .islandGlass(Capsule(), tint: FloatingSurfaceTheme.chipFill(colorScheme), solidTint: FloatingSurfaceTheme.surface(colorScheme))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("用量来源")
        }
    }

    @ViewBuilder
    private func telemetryTiles(resolvedHighlight: Color) -> some View {
        let compactLabels = available.count >= 4
        HStack(spacing: 5) {
            ForEach(available, id: \.self) { provider in
                let isSelected = selection == provider
                let tone = providerTones[provider] ?? .calm
                let warningTone: GlanceTone? = tone == .calm ? nil : tone
                let remaining = providerRemaining[provider] ?? nil
                let valueColor: Color = {
                    if tone == .critical {
                        return Color(red: 0.988, green: 0.490, blue: 0.465)
                    }
                    if tone == .tight {
                        return .orange
                    }
                    return isSelected
                        ? FloatingSurfaceTheme.primary(colorScheme)
                        : FloatingSurfaceTheme.primary(colorScheme).opacity(0.80)
                }()
                let barColor: Color = {
                    if tone == .critical { return GlanceTone.critical.color }
                    if tone == .tight { return GlanceTone.tight.color }
                    if isSelected { return resolvedHighlight }
                    return colorScheme == .dark ? Color.white.opacity(0.38) : Color.black.opacity(0.28)
                }()

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = provider }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 3) {
                            Text(label(for: provider, compact: compactLabels))
                                .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(
                                    isSelected
                                        ? FloatingSurfaceTheme.primary(colorScheme)
                                        : FloatingSurfaceTheme.secondary(colorScheme)
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.80)
                            Spacer(minLength: 2)
                            ProviderBrandIcon(
                                brand: brand(for: provider),
                                size: 11.5,
                                active: isSelected
                            )
                        }

                        Text(remaining.map { "\($0)%" } ?? "—")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(valueColor)
                            .lineLimit(1)

                        GeometryReader { proxy in
                            let fraction: CGFloat = {
                                guard let pct = remaining else { return 0 }
                                if pct <= 0 { return 0.06 }
                                return min(1.0, max(0.06, CGFloat(pct) / 100.0))
                            }()
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08))
                                if remaining != nil {
                                    Capsule()
                                        .fill(barColor)
                                        .frame(width: max(3, proxy.size.width * fraction))
                                }
                            }
                        }
                        .frame(height: 2.2)
                    }
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 5.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                        if isSelected {
                            shape
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            resolvedHighlight.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                            resolvedHighlight.opacity(colorScheme == .dark ? 0.08 : 0.05)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay {
                                    shape.strokeBorder(resolvedHighlight.opacity(0.46), lineWidth: 0.8)
                                }
                                .matchedGeometryEffect(id: "glance-provider", in: highlight)
                        } else {
                            shape
                                .fill(colorScheme == .dark ? Color.white.opacity(0.048) : Color.black.opacity(0.04))
                                .overlay(alignment: .top) {
                                    Rectangle()
                                        .fill(Color.white.opacity(colorScheme == .dark ? 0.11 : 0.25))
                                        .frame(height: 0.5)
                                        .padding(.horizontal, 8)
                                        .accessibilityHidden(true)
                                }
                                .overlay {
                                    if let warningTone {
                                        shape.strokeBorder(warningTone.color.opacity(0.26), lineWidth: 0.6)
                                    }
                                }
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(FloatingSurfaceButtonStyle())
                .help(
                    accessibilityName(for: provider)
                        + (remaining.map { " · 剩余 \($0)%" } ?? "")
                        + (warningTone == .critical ? " · 额度告急" : (warningTone == .tight ? " · 额度偏紧" : ""))
                )
                .accessibilityLabel(accessibilityName(for: provider))
                .accessibilityValue(
                    (isSelected ? "已选择" : "未选择")
                        + (remaining.map { "，剩余 \($0)%" } ?? "")
                        + (warningTone == .critical ? "，额度告急" : (warningTone == .tight ? "，额度偏紧" : ""))
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func compactPills(resolvedHighlight: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(available, id: \.self) { provider in
                let isSelected = selection == provider
                let warningTone = providerTones[provider].flatMap { $0 == .calm ? nil : $0 }
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = provider }
                } label: {
                    HStack(spacing: 4) {
                        ProviderBrandIcon(brand: brand(for: provider), size: 11, active: isSelected)
                        Text(label(for: provider, compact: false))
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .foregroundStyle(isSelected ? FloatingSurfaceTheme.primary(colorScheme) : FloatingSurfaceTheme.secondary(colorScheme))
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(resolvedHighlight.opacity(0.24))
                                .overlay {
                                    Capsule().strokeBorder(resolvedHighlight.opacity(0.42), lineWidth: 0.5)
                                }
                                .matchedGeometryEffect(id: "glance-provider-compact", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(FloatingSurfaceButtonStyle())
                .help(accessibilityName(for: provider) + (warningTone == .critical ? " · 额度告急" : (warningTone == .tight ? " · 额度偏紧" : "")))
                .accessibilityLabel(accessibilityName(for: provider))
                .accessibilityValue((isSelected ? "已选择" : "未选择") + (warningTone == .critical ? "，额度告急" : (warningTone == .tight ? "，额度偏紧" : "")))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
    }
}

struct GlanceConcentricQuotaRing: View {
    let primaryFraction: Double
    let secondaryFraction: Double?
    let primaryColor: Color
    var secondaryColor: Color = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
    var dimmed: Bool = false

    private func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    var body: some View {
        let outer = clamped(primaryFraction)
        let inner = secondaryFraction.map(clamped)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 5)
                .frame(width: 52, height: 52)
            Circle()
                .trim(from: 0, to: outer)
                .stroke(primaryColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 52, height: 52)
                .rotationEffect(.degrees(-90))

            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: 4.5)
                .frame(width: 36, height: 36)
            if let inner {
                Circle()
                    .trim(from: 0, to: inner)
                    .stroke(secondaryColor, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: outer)
                    .stroke(primaryColor.opacity(0.36), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 62, height: 62)
        .opacity(dimmed ? 0.56 : 1)
        .accessibilityHidden(true)
    }
}

struct GlanceHeroQuotaCard<Badge: View, FooterTrailing: View>: View {
    static var unifiedHeight: CGFloat { 138 }

    let title: String
    let remainingPercent: Int
    let primaryCopy: String
    let secondaryCopy: String
    let weatherColor: Color
    var secondaryRingPercent: Int? = nil
    var footerLeft: String? = nil
    var footerRight: String? = nil
    var warningNote: String? = nil
    var isStale: Bool = false
    @ViewBuilder var inlineBadge: () -> Badge
    @ViewBuilder var footerTrailing: () -> FooterTrailing
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        remainingPercent: Int,
        primaryCopy: String,
        secondaryCopy: String,
        weatherColor: Color,
        secondaryRingPercent: Int? = nil,
        footerLeft: String? = nil,
        footerRight: String? = nil,
        warningNote: String? = nil,
        isStale: Bool = false,
        @ViewBuilder inlineBadge: @escaping () -> Badge,
        @ViewBuilder footerTrailing: @escaping () -> FooterTrailing = { EmptyView() }
    ) {
        self.title = title
        self.remainingPercent = remainingPercent
        self.primaryCopy = primaryCopy
        self.secondaryCopy = secondaryCopy
        self.weatherColor = weatherColor
        self.secondaryRingPercent = secondaryRingPercent
        self.footerLeft = footerLeft
        self.footerRight = footerRight
        self.warningNote = warningNote
        self.isStale = isStale
        self.inlineBadge = inlineBadge
        self.footerTrailing = footerTrailing
    }

    private var innerRingColor: Color {
        guard let sec = secondaryRingPercent else {
            return Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
        }
        if sec < 20 { return .red }
        if sec < 50 { return .orange }
        return Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(FloatingSurfaceTheme.detail(colorScheme))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        inlineBadge()
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(remainingPercent)")
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("%")
                            .font(.system(size: 19, weight: .medium, design: .rounded))
                            .foregroundStyle(FloatingSurfaceTheme.detail(colorScheme))
                    }
                    .glanceReadableText()
                    .opacity(isStale ? 0.58 : 1)
                    .accessibilityLabel((isStale ? "上次观测，非当前。" : "") + "剩余 \(remainingPercent)%")

                    Text(primaryCopy)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .glanceReadableText()

                    Text(secondaryCopy)
                        .font(.system(size: 9.5))
                        .foregroundStyle(FloatingSurfaceTheme.secondary(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                GlanceConcentricQuotaRing(
                    primaryFraction: Double(remainingPercent) / 100.0,
                    secondaryFraction: secondaryRingPercent.map { Double($0) / 100.0 },
                    primaryColor: weatherColor,
                    secondaryColor: innerRingColor,
                    dimmed: isStale
                )
            }

            Spacer(minLength: 4)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 0.5)
                .padding(.bottom, 6)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                if let warningNote {
                    Text(warningNote)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                } else {
                    Text(footerLeft ?? "官方配额实时同步")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(FloatingSurfaceTheme.detail(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 4)
                footerTrailing()
                if let footerRight {
                    Text(footerRight)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(FloatingSurfaceTheme.detail(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.unifiedHeight)
        .background(
            LinearGradient(
                colors: [weatherColor.opacity(colorScheme == .dark ? 0.13 : 0.08), Color.white.opacity(0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: 0.5)
                .padding(.horizontal, 16)
                .accessibilityHidden(true)
        }
    }
}

struct GlanceEmptyQuotaCard<Trailing: View, ActionContent: View>: View {
    let title: String
    let message: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var action: () -> ActionContent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(FloatingSurfaceTheme.detail(colorScheme))
                        Spacer(minLength: 0)
                        trailing()
                    }
                    Text("—")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .foregroundStyle(FloatingSurfaceTheme.secondary(colorScheme))
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(FloatingSurfaceTheme.secondary(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                GlanceConcentricQuotaRing(
                    primaryFraction: 0,
                    secondaryFraction: 0,
                    primaryColor: FloatingSurfaceTheme.secondary(colorScheme),
                    dimmed: true
                )
            }
            Spacer(minLength: 4)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text("等待配额窗口同步")
                    .font(.system(size: 9.5))
                    .foregroundStyle(FloatingSurfaceTheme.secondary(colorScheme))
                Spacer(minLength: 4)
                action()
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: GlanceHeroQuotaCard<EmptyView, EmptyView>.unifiedHeight)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 0.5)
                .padding(.horizontal, 16)
                .accessibilityHidden(true)
        }
    }
}

private struct GlanceMetricTabs: View {
    @Binding var selection: GlanceStripMetric
    let showsSelector: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline
    @FocusState private var focusedMetric: GlanceStripMetric?

    var body: some View {
        if showsSelector {
            HStack(spacing: 10) {
                ForEach(GlanceStripMetric.allCases, id: \.self) { item in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = item }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                            .foregroundStyle(selection == item ? FloatingSurfaceTheme.primary(colorScheme) : FloatingSurfaceTheme.secondary(colorScheme))
                            .padding(.horizontal, 3).frame(minHeight: 32)
                            .overlay(alignment: .bottom) {
                                if selection == item {
                                    if reduceMotion {
                                        indicator
                                    } else {
                                        indicator.matchedGeometryEffect(id: "metric-underline", in: underline)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedMetric, equals: item)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(focusedMetric == item ? FloatingSurfaceTheme.accent(colorScheme) : .clear, lineWidth: 1)
                    }
                    .accessibilityLabel(item.title)
                    .accessibilityValue(selection == item ? "已选择" : "未选择")
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
                }
            }
            // Native segmented semantics for VoiceOver; the visible controls remain text buttons.
            .accessibilityRepresentation {
                Picker("七日条带指标，分段选择", selection: $selection) {
                    ForEach(GlanceStripMetric.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }.pickerStyle(.segmented)
                    .accessibilityValue(selection.title + "，已选择")
            }
        } else {
            Text(selection.title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FloatingSurfaceTheme.primary(colorScheme)).frame(minHeight: 32)
        }
    }

    private var indicator: some View {
        Capsule().fill(FloatingSurfaceTheme.primary(colorScheme)).frame(width: 14, height: 2)
    }
}
