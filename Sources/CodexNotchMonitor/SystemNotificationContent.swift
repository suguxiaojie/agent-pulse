import Foundation
import CryptoKit

/// Value-only payloads keep presentation and action routing testable without
/// requesting system permission or accessing the notification center.
struct SystemNotificationContent: Equatable {
    let identifier: String
    let title: String
    var subtitle = ""
    let body: String
    let category: String
    var sourceURL: String? = nil
    var playsSound = true

    var islandAlert: IslandAlert? {
        if category == "CREDIT_EXPIRY" {
            return IslandAlert(id: identifier, kind: .creditExpiry, title: title, subtitle: subtitle,
                body: body, isPendingSource: false, actions: [], sourceURL: nil)
        }
        let signal = category == "TIBO_SIGNAL"
        let pending = category == "QUOTA_RECOVERY_UNVERIFIED"
        guard signal || pending || category == "QUOTA_RECOVERY" else { return nil }
        let isProviderReset = identifier.hasPrefix("provider-reset-")
        var actions = [IslandAlert.Action(title: signal ? "在动态中心查看" : (isProviderReset ? "查看额度" : "查看重置记录"), route: .openCenter)]
        if signal { actions.append(.init(title: "打开原帖", route: .openSource)) }
        if pending { actions.append(.init(title: "标记为手动重置", route: .confirmManual)) }
        return IslandAlert(id: identifier, kind: signal ? .tiboSignal : .quotaRecovery,
            title: title, subtitle: subtitle, body: body, isPendingSource: pending,
            actions: actions, sourceURL: sourceURL)
    }

    static func recovery(_ event: QuotaResetEvent, isUpdate: Bool = false) -> Self {
        let pending = event.reason == .unverified
        return Self(
            identifier: event.notificationID ?? event.id,
            title: pending ? "额度已恢复至 100%" : event.reason.title + (isUpdate ? " · 已核对" : ""),
            body: recoveryDetails(event) + (pending ? "\n来源确认中…" : ""),
            category: pending ? "QUOTA_RECOVERY_UNVERIFIED" : "QUOTA_RECOVERY",
            sourceURL: event.sourceURL,
            playsSound: !isUpdate
        )
    }

    static func recoveryDetails(_ event: QuotaResetEvent) -> String {
        event.changes.map {
            "\($0.bucketName) \($0.windowLabel)：\($0.previousRemainingPercent)% → \($0.currentRemainingPercent)%"
        }.joined(separator: "；")
    }

    static func signal(_ signal: CodexResetRadarSignal, state: CodexResetPinnedSignalState) -> Self {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return Self(
            identifier: "tibo-signal-\(signal.tweetId)",
            title: state == .activePreview ? "Tibo 发布了重置预告" : "Tibo 发布了待验证的重置信号",
            subtitle: signal.date.map(formatter.string(from:)) ?? "",
            body: signal.displayText.count > 120 ? String(signal.displayText.prefix(120)) + "…" : signal.displayText,
            category: "TIBO_SIGNAL",
            sourceURL: signal.url
        )
    }

    static func providerQuotaReset(
        providerID: String,
        providerName: String,
        identifierSuffix: String,
        isMidCycleRecovery: Bool,
        details: [String]
    ) -> Self {
        Self(
            identifier: "provider-reset-\(providerID)-\(identifierSuffix)",
            title: isMidCycleRecovery ? "\(providerName) 额度已恢复" : "\(providerName) 额度已重置",
            body: details.joined(separator: "；"),
            category: "QUOTA_RECOVERY",
            playsSound: true
        )
    }
}

struct ProviderQuotaWindowObservation: Equatable, Sendable {
    let providerID: String
    let providerName: String
    let windowID: String
    let windowTitle: String
    let remainingPercent: Int
    let resetsAt: Date?
    let capturedAt: Date
    let allowsMidCycleJump: Bool
}

/// Tracks consumed quota windows (remaining <= 80%) across Claude Code, Grok CLI, and Antigravity.
/// Fires deduplicated notifications when a consumed window reaches its `resetsAt` boundary
/// (or recovers mid-cycle for single-account polled providers like Grok / Antigravity).
struct ProviderQuotaResetLedger {
    static let consumptionThresholdPercent = 80
    static let maxCatchupAge: TimeInterval = 30 * 60
    static let sameCycleTolerance: TimeInterval = 90
    static let earlyBoundaryTolerance: TimeInterval = 120
    private static let maxNotifiedEntries = 200

    private struct TrackedWindow: Codable, Equatable {
        let providerID: String
        let providerName: String
        let windowID: String
        var windowTitle: String
        var resetsAt: Date
        var minRemainingPercent: Int
        var lastRemainingPercent: Int
        var lastCapturedAt: Date
    }

    private struct NotifiedCycle: Codable, Equatable {
        let key: String
        let recordedAt: Date
    }

    private struct Storage: Codable {
        var tracked: [String: TrackedWindow] = [:]
        var notified: [NotifiedCycle] = []
    }

    private var storage: Storage

    init(data: Data? = nil) {
        storage = data.flatMap { try? JSONDecoder().decode(Storage.self, from: $0) } ?? Storage()
    }

    var data: Data? { try? JSONEncoder().encode(storage) }

    mutating func clear(providerID: String) {
        storage.tracked = storage.tracked.filter { $0.value.providerID != providerID }
    }

    mutating func observe(
        _ observations: [ProviderQuotaWindowObservation],
        now: Date = Date(),
        enabled: Bool
    ) -> [SystemNotificationContent] {
        var pendingNotices: [String: (providerName: String, isMidCycle: Bool, details: [String], keys: [String])] = [:]

        func appendNotice(providerID: String, providerName: String, isMidCycle: Bool, detail: String, dedupeKey: String) {
            guard enabled else { return }
            let bucketKey = "\(providerID)|\(isMidCycle ? "jump" : "reset")"
            var entry = pendingNotices[bucketKey] ?? (providerName, isMidCycle, [], [])
            entry.details.append(detail)
            entry.keys.append(dedupeKey)
            pendingNotices[bucketKey] = entry
        }

        for obs in observations {
            guard (0...100).contains(obs.remainingPercent),
                  obs.capturedAt.timeIntervalSinceReferenceDate.isFinite,
                  obs.capturedAt <= now.addingTimeInterval(60) else { continue }
            let trackKey = "\(obs.providerID)|\(obs.windowID)"
            let previous = storage.tracked[trackKey]

            if let resetsAt = obs.resetsAt, resetsAt.timeIntervalSinceReferenceDate.isFinite {
                // Case 1: Snapshot itself belongs to a cycle whose resetsAt already passed.
                if resetsAt <= now {
                    if obs.capturedAt < resetsAt,
                       obs.remainingPercent <= Self.consumptionThresholdPercent,
                       now.timeIntervalSince(resetsAt) <= Self.maxCatchupAge {
                        let cycleKey = Self.cycleKey(providerID: obs.providerID, windowID: obs.windowID, resetsAt: resetsAt)
                        if !hasNotified(cycleKey) {
                            markNotified(cycleKey, now: now)
                            appendNotice(
                                providerID: obs.providerID,
                                providerName: obs.providerName,
                                isMidCycle: false,
                                detail: "\(obs.windowTitle)已到重置时间（此前剩余 \(obs.remainingPercent)%）",
                                dedupeKey: cycleKey
                            )
                        }
                    }
                    if let previous, abs(previous.resetsAt.timeIntervalSince(resetsAt)) <= Self.sameCycleTolerance {
                        storage.tracked.removeValue(forKey: trackKey)
                    }
                    continue
                }

                // Case 2: Active cycle (`resetsAt > now`). Compare against previously tracked cycle.
                if let prev = previous {
                    let isNewCycle = resetsAt.timeIntervalSince(prev.resetsAt) > Self.sameCycleTolerance
                    let prevDeadlineReached = now >= prev.resetsAt.addingTimeInterval(-Self.earlyBoundaryTolerance)
                    let prevWithinCatchup = now.timeIntervalSince(prev.resetsAt) <= Self.maxCatchupAge

                    if isNewCycle && prevDeadlineReached {
                        if prev.minRemainingPercent <= Self.consumptionThresholdPercent && prevWithinCatchup {
                            let cycleKey = Self.cycleKey(providerID: prev.providerID, windowID: prev.windowID, resetsAt: prev.resetsAt)
                            if !hasNotified(cycleKey) {
                                markNotified(cycleKey, now: now)
                                appendNotice(
                                    providerID: obs.providerID,
                                    providerName: obs.providerName,
                                    isMidCycle: false,
                                    detail: "\(obs.windowTitle)：\(prev.minRemainingPercent)% → \(obs.remainingPercent)%",
                                    dedupeKey: cycleKey
                                )
                            }
                        }
                        storage.tracked[trackKey] = TrackedWindow(
                            providerID: obs.providerID,
                            providerName: obs.providerName,
                            windowID: obs.windowID,
                            windowTitle: obs.windowTitle,
                            resetsAt: resetsAt,
                            minRemainingPercent: obs.remainingPercent,
                            lastRemainingPercent: obs.remainingPercent,
                            lastCapturedAt: obs.capturedAt
                        )
                        continue
                    }

                    if !isNewCycle {
                        // Same cycle (or minor clock drift): check mid-cycle recovery if allowed.
                        if obs.allowsMidCycleJump,
                           obs.capturedAt > prev.lastCapturedAt,
                           obs.capturedAt.timeIntervalSince(prev.lastCapturedAt) <= 6 * 3600,
                           prev.lastRemainingPercent <= Self.consumptionThresholdPercent,
                           obs.remainingPercent >= 99,
                           obs.remainingPercent - prev.lastRemainingPercent >= 5 {
                            let jumpKey = Self.midCycleKey(
                                providerID: obs.providerID,
                                windowID: obs.windowID,
                                resetsAt: resetsAt,
                                capturedAt: obs.capturedAt
                            )
                            if !hasNotified(jumpKey) {
                                markNotified(jumpKey, now: now)
                                appendNotice(
                                    providerID: obs.providerID,
                                    providerName: obs.providerName,
                                    isMidCycle: true,
                                    detail: "\(obs.windowTitle)：\(prev.lastRemainingPercent)% → \(obs.remainingPercent)%",
                                    dedupeKey: jumpKey
                                )
                            }
                            storage.tracked[trackKey] = TrackedWindow(
                                providerID: obs.providerID,
                                providerName: obs.providerName,
                                windowID: obs.windowID,
                                windowTitle: obs.windowTitle,
                                resetsAt: resetsAt,
                                minRemainingPercent: obs.remainingPercent,
                                lastRemainingPercent: obs.remainingPercent,
                                lastCapturedAt: obs.capturedAt
                            )
                            continue
                        }

                        var updated = prev
                        updated.windowTitle = obs.windowTitle
                        updated.resetsAt = resetsAt
                        if obs.capturedAt >= prev.lastCapturedAt {
                            updated.minRemainingPercent = min(prev.minRemainingPercent, obs.remainingPercent)
                            updated.lastRemainingPercent = obs.remainingPercent
                            updated.lastCapturedAt = obs.capturedAt
                        }
                        storage.tracked[trackKey] = updated
                        continue
                    }

                    // `resetsAt` shifted significantly BEFORE `prev.resetsAt` (e.g. account switch on Claude or early reset on Grok).
                    if obs.allowsMidCycleJump,
                       obs.capturedAt > prev.lastCapturedAt,
                       obs.capturedAt.timeIntervalSince(prev.lastCapturedAt) <= 6 * 3600,
                       prev.lastRemainingPercent <= Self.consumptionThresholdPercent,
                       obs.remainingPercent >= 99,
                       obs.remainingPercent - prev.lastRemainingPercent >= 5 {
                        let jumpKey = Self.midCycleKey(
                            providerID: obs.providerID,
                            windowID: obs.windowID,
                            resetsAt: resetsAt,
                            capturedAt: obs.capturedAt
                        )
                        if !hasNotified(jumpKey) {
                            markNotified(jumpKey, now: now)
                            appendNotice(
                                providerID: obs.providerID,
                                providerName: obs.providerName,
                                isMidCycle: true,
                                detail: "\(obs.windowTitle)：\(prev.lastRemainingPercent)% → \(obs.remainingPercent)%",
                                dedupeKey: jumpKey
                            )
                        }
                    }
                    storage.tracked[trackKey] = TrackedWindow(
                        providerID: obs.providerID,
                        providerName: obs.providerName,
                        windowID: obs.windowID,
                        windowTitle: obs.windowTitle,
                        resetsAt: resetsAt,
                        minRemainingPercent: obs.remainingPercent,
                        lastRemainingPercent: obs.remainingPercent,
                        lastCapturedAt: obs.capturedAt
                    )
                } else {
                    storage.tracked[trackKey] = TrackedWindow(
                        providerID: obs.providerID,
                        providerName: obs.providerName,
                        windowID: obs.windowID,
                        windowTitle: obs.windowTitle,
                        resetsAt: resetsAt,
                        minRemainingPercent: obs.remainingPercent,
                        lastRemainingPercent: obs.remainingPercent,
                        lastCapturedAt: obs.capturedAt
                    )
                }
            }
        }

        var result = buildNotifications(from: pendingNotices)
        result.append(contentsOf: evaluateDueResets(now: now, enabled: enabled))
        return result
    }

    mutating func evaluateDueResets(
        now: Date = Date(),
        enabled: Bool
    ) -> [SystemNotificationContent] {
        var dueByProvider: [String: (providerName: String, isMidCycle: Bool, details: [String], keys: [String])] = [:]
        let keys = storage.tracked.keys.sorted()

        for trackKey in keys {
            guard let tracked = storage.tracked[trackKey], tracked.resetsAt <= now else { continue }
            storage.tracked.removeValue(forKey: trackKey)
            guard tracked.minRemainingPercent <= Self.consumptionThresholdPercent else { continue }
            let cycleKey = Self.cycleKey(providerID: tracked.providerID, windowID: tracked.windowID, resetsAt: tracked.resetsAt)
            guard !hasNotified(cycleKey) else { continue }
            markNotified(cycleKey, now: now)
            guard enabled, now.timeIntervalSince(tracked.resetsAt) <= Self.maxCatchupAge else { continue }
            let bucketKey = "\(tracked.providerID)|reset"
            var entry = dueByProvider[bucketKey] ?? (tracked.providerName, false, [], [])
            entry.details.append("\(tracked.windowTitle)已到重置时间（此前剩余 \(tracked.minRemainingPercent)%）")
            entry.keys.append(cycleKey)
            dueByProvider[bucketKey] = entry
        }

        return buildNotifications(from: dueByProvider)
    }

    private func buildNotifications(
        from grouped: [String: (providerName: String, isMidCycle: Bool, details: [String], keys: [String])]
    ) -> [SystemNotificationContent] {
        grouped.keys.sorted().compactMap { bucketKey in
            guard let entry = grouped[bucketKey], !entry.details.isEmpty else { return nil }
            let providerID = bucketKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? bucketKey
            let digest = SHA256.hash(data: Data(entry.keys.sorted().joined(separator: "|").utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
            return SystemNotificationContent.providerQuotaReset(
                providerID: providerID,
                providerName: entry.providerName,
                identifierSuffix: String(digest),
                isMidCycleRecovery: entry.isMidCycle,
                details: entry.details
            )
        }
    }

    private func hasNotified(_ key: String) -> Bool {
        storage.notified.contains { $0.key == key }
    }

    private mutating func markNotified(_ key: String, now: Date) {
        storage.notified.removeAll { $0.key == key }
        storage.notified.append(NotifiedCycle(key: key, recordedAt: now))
        if storage.notified.count > Self.maxNotifiedEntries {
            storage.notified.removeFirst(storage.notified.count - Self.maxNotifiedEntries)
        }
    }

    private static func cycleKey(providerID: String, windowID: String, resetsAt: Date) -> String {
        let bucket = Int((resetsAt.timeIntervalSince1970 / 300.0).rounded())
        return "\(providerID)|\(windowID)|cycle:\(bucket)"
    }

    private static func midCycleKey(providerID: String, windowID: String, resetsAt: Date, capturedAt: Date) -> String {
        let resetBucket = Int((resetsAt.timeIntervalSince1970 / 300.0).rounded())
        let captureBucket = Int((capturedAt.timeIntervalSince1970 / 600.0).rounded())
        return "\(providerID)|\(windowID)|jump:\(resetBucket):\(captureBucket)"
    }
}

/// Thresholds are evaluated only against a successful, account-matched quota read.
/// Persist the most urgent announced stage so restarts cannot replay older stages.
struct CreditExpiryReminderLedger {
    private struct Entry: Codable {
        let expiry: Date
        let hours: Int
    }
    private var entries: [String: Entry]
    init(data: Data? = nil) {
        entries = data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    var data: Data? { try? JSONEncoder().encode(entries) }

    mutating func observe(_ summary: QuotaResetCreditSummary?, accountID: String?, now: Date) -> [SystemNotificationContent] {
        entries = entries.filter { $0.value.expiry > now }
        guard let accountID, !accountID.isEmpty, let summary, summary.availableCount > 0 else { return [] }
        var result: [SystemNotificationContent] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for credit in summary.credits {
            guard credit.status.lowercased() == "available", !credit.id.isEmpty,
                  !credit.id.hasPrefix("reset-credit-"),
                  let expiry = credit.expiresAt, expiry.timeIntervalSince1970.isFinite,
                  expiry > now,
                  let hours = [6, 12, 24].first(where: { expiry.timeIntervalSince(now) <= Double($0) * 3600 }) else { continue }
            let identity = [accountID, credit.id, String(expiry.timeIntervalSince1970)]
            guard let bytes = try? JSONEncoder().encode(identity) else { continue }
            let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if let previous = entries[key], previous.hours <= hours { continue }
            entries[key] = Entry(expiry: expiry, hours: hours)
            let name = credit.title?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            result.append(SystemNotificationContent(identifier: "credit-expiry-\(key)-\(hours)",
                title: "重置卡即将过期", subtitle: "\(hours) 小时内到期",
                body: "\(name.isEmpty ? "额度重置卡" : String(name.prefix(80)))将于 \(formatter.string(from: expiry)) 到期，请及时使用。",
                category: "CREDIT_EXPIRY"))
        }
        return result
    }
}
