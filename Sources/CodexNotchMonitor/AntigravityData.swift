import Foundation

enum AntigravitySurface: String, CaseIterable, Sendable {
    case app
    case ide
    case cli

    var directoryName: String {
        switch self {
        case .app: return "antigravity"
        case .ide: return "antigravity-ide"
        case .cli: return "antigravity-cli"
        }
    }

    var displayName: String {
        switch self {
        case .app: return "Antigravity 2.0"
        case .ide: return "Antigravity IDE"
        case .cli: return "Antigravity CLI"
        }
    }

    var shortName: String {
        switch self {
        case .app: return "桌面端"
        case .ide: return "IDE"
        case .cli: return "CLI"
        }
    }

    var processNames: Set<String> {
        switch self {
        case .app: return ["antigravity", "antigravity helper"]
        case .ide: return ["antigravity ide", "code helper"]
        case .cli: return ["agy", "agy_acp_server"]
        }
    }
}

struct AntigravityInstallationStatus: Equatable, Sendable {
    var appURL: URL?
    var ideURL: URL?
    var cliURL: URL?

    var anyInstalled: Bool { appURL != nil || ideURL != nil || cliURL != nil }

    var summaryText: String {
        var found: [String] = []
        if appURL != nil { found.append("2.0 桌面端") }
        if ideURL != nil { found.append("IDE") }
        if cliURL != nil { found.append("agy CLI") }
        return found.isEmpty ? "未检测到客户端" : found.joined(separator: " / ")
    }

    static func detect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let fm = FileManager.default
        func findApp(_ name: String) -> URL? {
            let candidates = [
                URL(fileURLWithPath: "/Applications/\(name)", isDirectory: true),
                home.appendingPathComponent("Applications/\(name)", isDirectory: true)
            ]
            return candidates.first { fm.fileExists(atPath: $0.path) }
        }
        func findCLI() -> URL? {
            var candidates: [String] = [
                home.appendingPathComponent(".local/bin/agy").path,
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy"
            ]
            if let pathEnv = environment["PATH"] {
                for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
                    candidates.append(String(dir) + "/agy")
                }
            }
            for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            }
            return nil
        }
        return Self(
            appURL: findApp("Antigravity.app"),
            ideURL: findApp("Antigravity IDE.app"),
            cliURL: findCLI()
        )
    }
}

enum AntigravityMath {
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs > 0 else { return lhs }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        let raw = number.doubleValue
        guard raw >= 0, raw <= Double(Int.max), raw.rounded() == raw else { return nil }
        return Int(raw)
    }
}

enum AntigravityPlanDisplayName {
    static func resolve(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        switch normalized {
        case "free", "individual", "free_tier":
            return "Free"
        case "plus", "ai_plus", "google_ai_plus":
            return "Google AI Plus"
        case "pro", "ai_pro", "google_ai_pro":
            return "Google AI Pro"
        case "ultra", "ai_ultra", "google_ai_ultra", "ultra_5x", "google_ai_ultra_5x":
            return "Google AI Ultra"
        case "ultra_20x", "google_ai_ultra_20x":
            return "Google AI Ultra 20x"
        case "enterprise", "gemini_enterprise", "organization", "workspace":
            return "Gemini Enterprise"
        default:
            return String(trimmed.prefix(32))
        }
    }
}

struct AntigravityQuotaWindow: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let remainingPercent: Int
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?
    let sortPriority: Int

    func isValid(capturedAt: Date, now: Date, staleCutoff: TimeInterval = 300) -> Bool {
        guard usedPercent.isFinite, (0...100).contains(usedPercent),
              (0...100).contains(remainingPercent),
              capturedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt.timeIntervalSince(now) <= 60 else { return false }
        if let resetsAt {
            return resetsAt.timeIntervalSinceReferenceDate.isFinite && resetsAt > now
        }
        return now.timeIntervalSince(capturedAt) <= staleCutoff
    }
}

struct AntigravityQuotaSnapshot: Equatable, Sendable {
    static let uiStaleThreshold: TimeInterval = 1_800

    let windows: [AntigravityQuotaWindow]
    let planTier: String?
    let aiCredits: Int?
    let useG1Credits: Bool?
    let capturedAt: Date

    var resolvedPlan: String? { AntigravityPlanDisplayName.resolve(planTier) }

    func activeWindows(at now: Date, staleCutoff: TimeInterval = 300) -> [AntigravityQuotaWindow] {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt.timeIntervalSince(now) <= 60 else { return [] }
        return windows.filter { $0.isValid(capturedAt: capturedAt, now: now, staleCutoff: staleCutoff) }
    }

    func isStale(at now: Date, threshold: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(capturedAt) > threshold
    }

    func rolledOverGeminiFiveHour(at now: Date, staleCutoff: TimeInterval = uiStaleThreshold) -> AntigravityQuotaWindow? {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt.timeIntervalSince(now) <= 60,
              now.timeIntervalSince(capturedAt) <= staleCutoff else { return nil }
        return windows.first { window in
            guard window.durationMinutes == 300,
                  window.id.lowercased(with: Locale(identifier: "en_US_POSIX")).contains("gemini"),
                  let resetsAt = window.resetsAt,
                  resetsAt.timeIntervalSinceReferenceDate.isFinite else { return false }
            return resetsAt > capturedAt && resetsAt <= now && now.timeIntervalSince(resetsAt) <= 18_000
        }
    }

    func mergingMetadata(from fallback: Self?) -> Self {
        guard let fallback else { return self }
        return Self(
            windows: windows.isEmpty ? fallback.windows : windows,
            planTier: planTier ?? fallback.planTier,
            aiCredits: aiCredits ?? fallback.aiCredits,
            useG1Credits: useG1Credits ?? fallback.useG1Credits,
            capturedAt: capturedAt
        )
    }

    static func decode(snapshot data: Data) -> Self? {
        guard data.count <= 262_144,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return decode(object: object)
    }

    static func decode(object: [String: Any], fallbackDate: Date? = nil) -> Self? {
        let capturedSeconds = (object["capturedAt"] as? NSNumber)?.doubleValue
        let observedText = (object["observed_at"] as? String) ?? (object["observedAt"] as? String)
        let capturedAt: Date
        if let capturedSeconds, capturedSeconds.isFinite, capturedSeconds > 0 {
            capturedAt = Date(timeIntervalSince1970: capturedSeconds)
        } else if let observedText,
                  let parsedObserved = FastTimestamp.parse(observedText) ?? parseISO8601(observedText) {
            capturedAt = parsedObserved
        } else if let fallbackDate {
            capturedAt = fallbackDate
        } else {
            return nil
        }

        let facts = (object["facts"] as? [String: Any]) ?? object
        let planTier = (object["plan_tier"] as? String)
            ?? (object["planTier"] as? String)
            ?? (facts["plan_tier"] as? String)
            ?? (facts["planTier"] as? String)
        let aiCredits = parseCredits(object) ?? parseCredits(facts)
        let useG1Credits: Bool? = ["useG1Credits", "use_ai_credits", "useAiCredits", "enable_ai_credits", "enableAiCredits"]
            .lazy
            .compactMap { key -> Bool? in
                if let num = object[key] as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() {
                    return num.boolValue
                }
                if let num = facts[key] as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() {
                    return num.boolValue
                }
                return nil
            }
            .first

        var windows: [AntigravityQuotaWindow] = []
        let quotaDict = (object["quota"] as? [String: Any]) ?? (facts["quota"] as? [String: Any])
        if let quotaDict {
            for key in quotaDict.keys.sorted() {
                guard let entry = quotaDict[key] as? [String: Any],
                      let parsed = parseWindow(id: key, entry: entry, capturedAt: capturedAt) else { continue }
                windows.append(parsed)
            }
        }
        windows.sort {
            if $0.sortPriority != $1.sortPriority { return $0.sortPriority < $1.sortPriority }
            if $0.remainingPercent != $1.remainingPercent { return $0.remainingPercent < $1.remainingPercent }
            return $0.id < $1.id
        }

        guard !windows.isEmpty || planTier != nil || aiCredits != nil else { return nil }
        return Self(
            windows: windows,
            planTier: planTier,
            aiCredits: aiCredits,
            useG1Credits: useG1Credits,
            capturedAt: capturedAt
        )
    }

    private static func parseCredits(_ object: [String: Any]) -> Int? {
        for key in ["credits", "ai_credits", "aiCredits"] {
            if let direct = AntigravityMath.nonNegativeInt(object[key]) { return direct }
            if let dict = object[key] as? [String: Any],
               let nested = AntigravityMath.nonNegativeInt(dict["remaining"])
                ?? AntigravityMath.nonNegativeInt(dict["balance"])
                ?? AntigravityMath.nonNegativeInt(dict["available"]) {
                return nested
            }
        }
        return nil
    }

    private static func parseWindow(id: String, entry: [String: Any], capturedAt: Date) -> AntigravityQuotaWindow? {
        let remainingFraction: Double? = {
            for key in ["remaining_fraction", "remainingFraction"] {
                if let num = entry[key] as? NSNumber,
                   CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite {
                    return num.doubleValue
                }
            }
            for key in ["remaining_percent", "remainingPercent"] {
                if let num = entry[key] as? NSNumber,
                   CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite {
                    return num.doubleValue / 100.0
                }
            }
            for key in ["used_percent", "usedPercent"] {
                if let num = entry[key] as? NSNumber,
                   CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite {
                    return (100.0 - num.doubleValue) / 100.0
                }
            }
            return nil
        }()
        guard let fraction = remainingFraction, fraction.isFinite, (-0.001...1.001).contains(fraction) else {
            return nil
        }
        let clamped = min(1.0, max(0.0, fraction))
        let remainingPercent = Int((clamped * 100.0).rounded())
        let usedPercent = (1.0 - clamped) * 100.0

        var resetsAt: Date?
        if let resetText = (entry["reset_time"] as? String)
            ?? (entry["resetTime"] as? String)
            ?? (entry["resets_at"] as? String)
            ?? (entry["resetsAt"] as? String),
           let parsed = FastTimestamp.parse(resetText) ?? parseISO8601(resetText) {
            resetsAt = parsed
        } else if let epochNum = (entry["resets_at"] as? NSNumber)
                    ?? (entry["resetsAt"] as? NSNumber)
                    ?? (entry["reset_time"] as? NSNumber)
                    ?? (entry["resetTime"] as? NSNumber),
                  CFGetTypeID(epochNum) != CFBooleanGetTypeID(),
                  epochNum.doubleValue.isFinite,
                  epochNum.doubleValue > 946_684_800,
                  epochNum.doubleValue < 4_102_444_800 {
            resetsAt = Date(timeIntervalSince1970: epochNum.doubleValue)
        } else if let secondsNum = (entry["reset_in_seconds"] as? NSNumber) ?? (entry["resetInSeconds"] as? NSNumber),
                  CFGetTypeID(secondsNum) != CFBooleanGetTypeID(),
                  secondsNum.doubleValue.isFinite, secondsNum.doubleValue > 0,
                  secondsNum.doubleValue <= 31_536_000 {
            resetsAt = capturedAt.addingTimeInterval(secondsNum.doubleValue)
        }

        let meta = classifyWindow(id: id)
        return AntigravityQuotaWindow(
            id: id,
            title: meta.title,
            remainingPercent: remainingPercent,
            usedPercent: usedPercent,
            durationMinutes: meta.minutes,
            resetsAt: resetsAt,
            sortPriority: meta.priority
        )
    }

    private static func classifyWindow(id: String) -> (title: String, minutes: Int?, priority: Int) {
        let lower = id.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let isFiveHour = lower.contains("5h") || lower.contains("five_hour") || lower.contains("rolling") || lower.contains("300m")
        let isWeekly = lower.contains("week") || lower.contains("7d") || lower.contains("seven_day")
        let minutes: Int? = isFiveHour ? 300 : (isWeekly ? 10_080 : nil)

        if lower.contains("gemini") {
            if isFiveHour { return ("Gemini 5 小时额度", 300, 0) }
            if isWeekly { return ("Gemini 每周额度", 10_080, 1) }
            return ("Gemini 额度", minutes, 2)
        }
        if lower.contains("3p") || lower.contains("third_party") || lower.contains("partner") {
            if isFiveHour { return ("合作模型 5 小时", 300, 3) }
            if isWeekly { return ("合作模型每周", 10_080, 4) }
            return ("合作模型额度", minutes, 5)
        }
        if lower.contains("claude") {
            if isFiveHour { return ("Claude 5 小时额度", 300, 3) }
            if isWeekly { return ("Claude 每周额度", 10_080, 4) }
            return ("Claude 合作额度", minutes, 5)
        }
        if lower.contains("gpt") {
            return ("GPT 合作额度", minutes, 6)
        }
        if isFiveHour { return ("5 小时额度", 300, 1) }
        if isWeekly { return ("每周额度", 10_080, 2) }
        return ("额度窗口", minutes, 7)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}

enum AntigravityPricing {
    private static let effortSuffixes: [String: String] = [
        "low": "Low",
        "medium": "Medium",
        "high": "High",
        "xhigh": "XHigh",
        "max": "Max"
    ]

    private static let orchestratorAliases: [String: String] = [
        "orchestrator": "gemini-pro-orchestrator",
        "orchestrator-carbon": "gemini-pro-orchestrator",
        "orchestrator-neon": "gemini-pro-orchestrator-neon",
        "orchestrator-argon": "gemini-pro-orchestrator-argon"
    ]

    // Scheduled Google API rate transitions (UTC):
    // - Gemini 4 Carbon / Argon: promotional $2/$0.10/$10 through 2026-11-30, $4/$0.20/$20 starting 2026-12-01.
    // - Gemini 3.8 Flash: introductory $0.75/$0.075/$3.75 through 2026-12-31, $1.50/$0.15/$7.50 starting 2027-01-01.
    private static let gemini4StandardRateStart = Date(timeIntervalSince1970: 1_796_083_200) // 2026-12-01T00:00:00Z
    private static let gemini38StandardRateStart = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01T00:00:00Z

    /// Normalizes either a transcript slug (`gemini-4-carbon-medium`, `gemini/gemini-3.8-flash-high`)
    /// or a statusLine display label (`Gemini 4 Neon (High)`, `Orchestrator (Carbon)`, `Claude Sonnet 5.5 (Medium)`)
    /// into `(baseSlug, fullSlug, displayEffort)`.
    static func canonicalModel(_ rawModel: String?, explicitEffort: String? = nil) -> (base: String, full: String, effort: String?) {
        var detectedEffort = explicitEffort.flatMap(cleanEffort)
        guard let rawModel else { return ("", "", detectedEffort) }
        var baseText = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty else { return ("", "", detectedEffort) }

        if let slashIdx = baseText.lastIndex(of: "/") {
            baseText = String(baseText[baseText.index(after: slashIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var parenVariant: String?
        if baseText.hasSuffix(")"), let openParen = baseText.lastIndex(of: "("), openParen > baseText.startIndex {
            let inside = baseText[baseText.index(after: openParen)..<baseText.index(before: baseText.endIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            if let mapped = effortSuffixes[inside] {
                if detectedEffort == nil { detectedEffort = mapped }
                baseText = String(baseText[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if ["carbon", "neon", "argon"].contains(inside) {
                parenVariant = inside
                baseText = String(baseText[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var slug = baseText
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
        if let parenVariant {
            slug = "\(slug)-\(parenVariant)"
        }
        if slug.hasPrefix("claude-") {
            slug = normalizeClaudeDecimalVersion(slug)
        }
        if let mappedOrch = orchestratorAliases[slug] {
            slug = mappedOrch
        }

        var parts = slug.split(separator: "-").map(String.init)
        let fullSlug = parts.joined(separator: "-")
        if let last = parts.last, let mapped = effortSuffixes[last], parts.count > 1 {
            if detectedEffort == nil { detectedEffort = mapped }
            parts.removeLast()
        }
        var baseSlug = parts.joined(separator: "-")
        if let mappedOrch = orchestratorAliases[baseSlug] {
            baseSlug = mappedOrch
        }
        return (baseSlug, fullSlug, detectedEffort)
    }

    private static func normalizeClaudeDecimalVersion(_ slug: String) -> String {
        let chars = Array(slug)
        guard chars.count >= 3 else { return slug }
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        for idx in chars.indices {
            if chars[idx] == ".", idx > 0, idx + 1 < chars.count,
               chars[idx - 1].isNumber, chars[idx + 1].isNumber {
                out.append("-")
            } else {
                out.append(chars[idx])
            }
        }
        return String(out)
    }

    static func formatModel(_ rawModel: String?, explicitEffort: String? = nil) -> (model: String, effort: String?) {
        let canonical = canonicalModel(rawModel, explicitEffort: explicitEffort)
        guard !canonical.base.isEmpty else { return ("", canonical.effort) }

        let stem = canonical.base
        let parts = stem.split(separator: "-").map(String.init)
        let display: String
        if stem == "gemini-pro-orchestrator" {
            display = "Orchestrator"
        } else if stem.hasPrefix("gemini-pro-orchestrator-") {
            let variant = String(stem.dropFirst("gemini-pro-orchestrator-".count)).capitalized
            display = "Orchestrator (\(variant))"
        } else if stem.hasPrefix("claude-") {
            display = formatClaudeStem(parts)
        } else if stem.hasPrefix("gpt-oss-") {
            let rest = parts.dropFirst(2).map { $0.uppercased() }.joined(separator: " ")
            display = rest.isEmpty ? "GPT-OSS" : "GPT-OSS \(rest)"
        } else if stem.hasPrefix("gemini-") {
            let formatted = parts.dropFirst().map { token -> String in
                if token.allSatisfy({ $0.isNumber || $0 == "." }) { return token }
                return token.capitalized
            }.joined(separator: " ")
            display = formatted.isEmpty ? "Gemini" : "Gemini \(formatted)"
        } else {
            display = parts.map { $0.capitalized }.joined(separator: " ")
        }
        return (display, canonical.effort)
    }

    private static func formatClaudeStem(_ parts: [String]) -> String {
        guard parts.count >= 2 else { return "Claude" }
        let family = parts[1].capitalized
        let remaining = Array(parts.dropFirst(2))
        if remaining.count >= 2, remaining[0].allSatisfy(\.isNumber), remaining[1].allSatisfy(\.isNumber),
           remaining[1].count <= 2 {
            let tail = remaining.dropFirst(2).map(\.capitalized).joined(separator: " ")
            let ver = "\(remaining[0]).\(remaining[1])"
            return ["Claude", family, ver, tail].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let tail = remaining.map(\.capitalized).joined(separator: " ")
        return ["Claude", family, tail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func cleanEffort(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return effortSuffixes[trimmed.lowercased()] ?? trimmed.capitalized
    }

    /// API-equivalent estimate for models with published official standard rates (Google AI / Vertex AI,
    /// Anthropic Claude partner pool, and GPT-OSS). Unrecognized or unpublished internal models return `nil`
    /// so Pulse preserves an honest `≥` lower bound without fabricating prices.
    static func estimateCost(
        model: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        at timestamp: Date? = nil
    ) -> Double? {
        guard inputTokens >= 0, cacheReadTokens >= 0, outputTokens >= 0 else { return nil }
        let canonical = canonicalModel(model)
        let base = canonical.base
        guard !base.isEmpty else { return nil }

        if base.hasPrefix("claude-") {
            let usage = ClaudeCodeTokenUsage(
                input: Int64(inputTokens),
                output: Int64(outputTokens),
                cacheRead: Int64(cacheReadTokens)
            )
            return ClaudeCodePricing.cost(model: base, usage: usage)
        }

        let effectiveDate = timestamp ?? Date()
        let totalPrompt = AntigravityMath.add(inputTokens, cacheReadTokens)
        let rates: (input: Double, cacheRead: Double, output: Double)?

        if base == "gemini-4-neon" || base.hasPrefix("gemini-4-neon-") || base == "gemini-pro-orchestrator-neon" {
            rates = (3.00, 0.15, 15.00)
        } else if base == "gemini-4-carbon" || base.hasPrefix("gemini-4-carbon-")
                    || base == "gemini-4-argon" || base.hasPrefix("gemini-4-argon-")
                    || base == "gemini-pro-orchestrator" || base == "gemini-pro-orchestrator-argon" {
            rates = effectiveDate >= gemini4StandardRateStart ? (4.00, 0.20, 20.00) : (2.00, 0.10, 10.00)
        } else if base == "gemini-4-hydrogen" || base.hasPrefix("gemini-4-hydrogen-") {
            rates = (1.50, 0.075, 7.50)
        } else if base == "gemini-3.8-flash" || base.hasPrefix("gemini-3.8-flash-") {
            rates = effectiveDate >= gemini38StandardRateStart ? (1.50, 0.15, 7.50) : (0.75, 0.075, 3.75)
        } else if base == "gemini-3.7-flash" || base.hasPrefix("gemini-3.7-flash-")
                    || base == "gemini-3.6-flash" || base.hasPrefix("gemini-3.6-flash-")
                    || base == "gemini-flash-latest" {
            rates = (0.75, 0.075, 3.75)
        } else if base.hasPrefix("gemini-3.5-flash-lite") || base == "gemini-flash-lite-latest" {
            rates = (0.30, 0.03, 2.50)
        } else if base == "gemini-3.5-flash" || base.hasPrefix("gemini-3.5-flash-")
                    || base.hasPrefix("gemini-omni-1.1-flash") || base.hasPrefix("gemini-omni-flash") {
            rates = (1.50, 0.15, 9.00)
        } else if base.hasPrefix("gemini-3.1-pro") || base.hasPrefix("gemini-3-pro") || base == "gemini-pro-latest" {
            rates = totalPrompt > 200_000 ? (4.00, 0.40, 18.00) : (2.00, 0.20, 12.00)
        } else if base.hasPrefix("gemini-3.1-flash-lite") {
            rates = (0.25, 0.025, 1.50)
        } else if base.hasPrefix("gemini-3.1-flash") || base.hasPrefix("gemini-3-flash") {
            rates = (0.50, 0.05, 3.00)
        } else if base.hasPrefix("gemini-2.5-pro") {
            rates = totalPrompt > 200_000 ? (2.50, 0.25, 15.00) : (1.25, 0.125, 10.00)
        } else if base.hasPrefix("gemini-2.5-flash-lite") {
            rates = (0.10, 0.01, 0.40)
        } else if base.hasPrefix("gemini-2.5-flash") {
            rates = (0.30, 0.03, 2.50)
        } else if base.hasPrefix("gemini-2.0-flash-lite") {
            rates = (0.075, 0.01875, 0.30)
        } else if base.hasPrefix("gemini-2.0-flash") {
            rates = (0.10, 0.025, 0.40)
        } else if base == "gpt-oss-120b" || base.hasPrefix("gpt-oss-120b-") {
            rates = (0.15, 0.0, 0.60)
        } else if base == "gpt-oss-20b" || base.hasPrefix("gpt-oss-20b-") {
            rates = (0.20, 0.0, 0.30)
        } else {
            rates = nil
        }

        guard let rates else { return nil }
        let total = (
            Double(inputTokens) * rates.input +
            Double(cacheReadTokens) * rates.cacheRead +
            Double(outputTokens) * rates.output
        ) / 1_000_000.0
        return total.isFinite && total >= 0 ? total : nil
    }
}

struct AntigravityUsageSummary: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        let date: Date
        var tokens: Int
        var inputTokens: Int
        var cacheReadTokens: Int
        var outputTokens: Int
        var knownCost: Double
        var hasUnpriced: Bool

        var cost: Double? { (hasUnpriced && knownCost == 0) ? nil : knownCost }
    }

    let days: [Day]
    let lifetimeTokens: Int
    let sessionCount: Int
    let complete: Bool
    let unpricedModels: [String]
    let updatedAt: Date

    func hasSameContent(as other: Self) -> Bool {
        days == other.days
            && lifetimeTokens == other.lifetimeTokens
            && sessionCount == other.sessionCount
            && complete == other.complete
            && unpricedModels == other.unpricedModels
    }
}
