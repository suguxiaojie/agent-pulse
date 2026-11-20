import Foundation

extension IslandUsagePresentation {
    static func antigravity(
        usage: AntigravityUsageSummary?,
        quota: AntigravityQuotaSnapshot?,
        statusLineEnabled: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self {
        let staleLimit = AntigravityQuotaSnapshot.uiStaleThreshold
        let activeWindows = statusLineEnabled ? (quota?.activeWindows(at: now, staleCutoff: staleLimit) ?? []) : []
        let isStale = quota?.isStale(at: now, threshold: staleLimit) ?? false
        let freshness: QuotaFreshness = {
            guard statusLineEnabled, let quota, !activeWindows.isEmpty else { return .unavailable }
            return isStale ? .stale(observedAt: quota.capturedAt) : .current
        }()

        let quotas: [Quota]
        if activeWindows.isEmpty {
            quotas = [
                Quota(
                    title: "Gemini 额度",
                    remainingPercent: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    freshness: .unavailable
                )
            ]
        } else {
            quotas = Array(activeWindows.prefix(2)).map { window in
                Quota(
                    title: window.title,
                    remainingPercent: window.remainingPercent,
                    usedPercent: Int(window.usedPercent.rounded()),
                    resetsAt: window.resetsAt,
                    freshness: freshness
                )
            }
        }

        let today = calendar.startOfDay(for: now)
        let lower = calendar.date(byAdding: .day, value: -29, to: today)!
        let byDate = Dictionary((usage?.days ?? []).map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
        let days = (0..<30).map { index -> IslandDashboardCost.Day in
            let date = calendar.date(byAdding: .day, value: index - 29, to: today)!
            if let day = byDate[date] {
                return .init(date: date, tokens: day.tokens, cost: day.cost)
            }
            return .init(
                date: date,
                tokens: usage?.complete == true ? 0 : nil,
                cost: usage?.complete == true ? 0 : nil
            )
        }

        let recorded = (usage?.days ?? []).filter { $0.date >= lower && $0.date <= today }
        let anyUnpriced = recorded.contains { $0.hasUnpriced }
        let knownSum = recorded.reduce(0.0) { $0 + $1.knownCost }
        let allRecordedUnpriced = !recorded.isEmpty && recorded.allSatisfy { $0.hasUnpriced && $0.knownCost == 0 }
        let total: Double? = {
            if recorded.isEmpty { return usage?.complete == true ? 0.0 : nil }
            if allRecordedUnpriced { return nil }
            return knownSum
        }()
        let lowerBound = anyUnpriced || usage?.complete == false
        let chart = IslandDashboardCost(claudeDays: days, latestRecordedDate: recorded.last?.date)

        var status: String
        if !statusLineEnabled {
            status = "Antigravity 状态栏额度采集未开启 · 历史覆盖本机三端记录"
        } else if activeWindows.isEmpty {
            status = "等待 agy CLI 状态栏同步额度 · 历史覆盖本机三端记录"
        } else {
            status = "Antigravity 官方额度 · Token 与成本覆盖本机三端记录"
        }
        if usage?.complete == false {
            status += " · 部分记录"
        }

        let visibleCredits = (statusLineEnabled && !isStale) ? quota?.aiCredits : nil

        return Self(
            provider: .antigravity,
            quotas: quotas,
            metrics: [
                .init(
                    title: "最近一天 Tokens",
                    tokens: usage == nil ? nil : (usage?.days.last?.tokens ?? 0),
                    dateTag: dateTag(usage?.days.last?.date, now: now, calendar: calendar)
                ),
                .init(
                    title: "30 天 Tokens",
                    tokens: usage == nil ? nil : recorded.reduce(0) { AntigravityMath.add($0, $1.tokens) },
                    dateTag: nil
                ),
                .init(title: "累计 Tokens", tokens: usage?.lifetimeTokens, dateTag: nil)
            ],
            cost: .init(
                title: "Antigravity 本地模型计价",
                total: total,
                totalIsLowerBound: lowerBound,
                note: usage?.complete == false ? "扫描中 · 部分记录" : (anyUnpriced ? "含未定价模型" : "最近 30 天"),
                days: days,
                latest: chart.latest,
                latestDateTag: dateTag(chart.latest?.date, now: now, calendar: calendar),
                maximum: chart.maximum,
                helpText: "覆盖本机 Antigravity 2.0、IDE 与 CLI 转录；按官方公开 API 单价估算等价成本，未标明模型或未公开单价的步骤保留下界（非订阅账单）。",
                accessibilityHint: "Antigravity 本机模型计价，非订阅账单"
            ),
            source: .antigravity(
                plan: quota?.resolvedPlan ?? "Antigravity",
                credits: visibleCredits,
                useG1Credits: quota?.useG1Credits
            ),
            activity: (usage?.days ?? []).map { .init(date: $0.date, tokens: $0.tokens) },
            lifetimeTokens: usage?.lifetimeTokens,
            activityHelp: "覆盖本机 Antigravity 2.0、IDE 与 CLI 全部可读会话，按本地日期统计。",
            statusLine: status,
            updatedAt: [statusLineEnabled ? quota?.capturedAt : nil, usage?.updatedAt].compactMap { $0 }.max(),
            supportsReset: false
        )
    }
}
