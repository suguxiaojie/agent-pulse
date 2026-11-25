import Darwin
import Foundation
import SQLite3

struct AntigravitySessionRecord: Equatable, Sendable {
    enum TurnPhase: String, Equatable, Sendable {
        case idle
        case working
        case tool
        case waitingQuestion
        case completed
        case failed
        case cancelled
    }

    struct StepItem: Equatable, Sendable {
        var id: String
        var title: String
        var status: String // "running", "waiting", "completed", "failed"
    }

    struct TurnSnapshot: Equatable, Sendable {
        var turnID: String?
        var phase: TurnPhase = .idle
        var startedAt: Date?
        var updatedAt = Date.distantPast
        /// Modification timestamp of `transcript.jsonl` when this turn's latest line was observed.
        /// Antigravity stamps `PLANNER_RESPONSE.created_at` at invocation start rather than finish,
        /// so `transcriptModifiedAt` captures the true flush/completion time without breaking synthetic tests.
        var transcriptModifiedAt: Date? = nil
        var tokens = 0
        var text = ""
        var steps: [StepItem] = []

        var isActive: Bool {
            switch phase {
            case .working, .tool, .waitingQuestion: return true
            case .idle, .completed, .failed, .cancelled: return false
            }
        }
    }

    enum SummaryStatus: Equatable, Sendable {
        case unknown
        case running
        case canceling
        case idle(modifiedAt: Date?)
        case killed
    }

    let id: String
    let surface: AntigravitySurface
    let cwd: String
    let title: String
    let model: String?
    let totalTokens: Int
    let isSubagent: Bool
    let isLockedLive: Bool
    let summaryBusy: Bool
    let summaryStatus: SummaryStatus
    let caughtUp: Bool
    let turn: TurnSnapshot

    init(
        id: String,
        surface: AntigravitySurface,
        cwd: String,
        title: String,
        model: String?,
        totalTokens: Int,
        isSubagent: Bool,
        isLockedLive: Bool,
        summaryBusy: Bool,
        summaryStatus: SummaryStatus? = nil,
        caughtUp: Bool,
        turn: TurnSnapshot
    ) {
        self.id = id
        self.surface = surface
        self.cwd = cwd
        self.title = title
        self.model = model
        self.totalTokens = totalTokens
        self.isSubagent = isSubagent
        self.isLockedLive = isLockedLive
        self.summaryBusy = summaryBusy
        self.summaryStatus = summaryStatus ?? (summaryBusy ? .running : .unknown)
        self.caughtUp = caughtUp
        self.turn = turn
    }
}

struct AntigravityScanResult: Equatable, Sendable {
    let usage: AntigravityUsageSummary
    let sessions: [AntigravitySessionRecord]
}

actor AntigravityScanner {
    static let maxReadBudgetPerPass = 16 * 1_048_576
    static let maxLineBytes = 524_288
    static let maxConversationsPerSurface = 1_024

    let geminiDirectory: URL
    let statusLineCacheDirectory: URL?
    private let calendar: Calendar
    private var fileCache: [String: CachedTranscript] = [:]
    private let liveLockOverride: (@Sendable (String, AntigravitySurface) -> Bool?)?

    private struct SummaryRow {
        var id: String
        var title: String
        var cwd: String
        var status: String
        var agentName: String
        var isSubagent: Bool
        var notFullyIdle: Bool
        var killed: Bool
        var modifiedAt: Date?
    }

    private struct DayAccumulator {
        var tokens = 0
        var inputTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var knownCost = 0.0
        var hasUnpriced = false
    }

    private struct AnonymousDayAccumulator {
        var inputTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var latestTimestamp = Date.distantPast
    }

    private struct CachedTranscript {
        var device: dev_t
        var inode: ino_t
        var offset: UInt64
        var seenSteps: Set<Int> = []
        var days: [Date: DayAccumulator] = [:]
        var anonymousDays: [Date: AnonymousDayAccumulator] = [:]
        var totalTokens = 0
        var unpricedModels: Set<String> = []
        var model: String?
        var fallbackTitle = ""
        var inferredCwd = ""
        var turn = AntigravitySessionRecord.TurnSnapshot()
        var pendingToolIndices: [Int] = []
        var complete = true
    }

    init(
        geminiDirectory: URL? = nil,
        statusLineCacheDirectory: URL? = nil,
        calendar: Calendar = .current,
        liveLockOverride: (@Sendable (String, AntigravitySurface) -> Bool?)? = nil
    ) {
        self.geminiDirectory = (geminiDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true))
            .standardizedFileURL
        if let statusLineCacheDirectory {
            self.statusLineCacheDirectory = statusLineCacheDirectory.standardizedFileURL
        } else {
            self.statusLineCacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cli-agents-\(getuid())", isDirectory: true)
                .appendingPathComponent("agy-statusline", isDirectory: true)
                .standardizedFileURL
        }
        self.calendar = calendar
        self.liveLockOverride = liveLockOverride
    }

    func scan(now: Date = Date()) -> AntigravityScanResult {
        var remainingBudget = Self.maxReadBudgetPerPass
        var allComplete = true
        var globalDays: [Date: DayAccumulator] = [:]
        var lifetimeTokens = 0
        var sessionCount = 0
        var allUnpriced: Set<String> = []
        var liveSessions: [AntigravitySessionRecord] = []
        var activeCacheKeys: Set<String> = []

        for surface in AntigravitySurface.allCases {
            let root = geminiDirectory.appendingPathComponent(surface.directoryName, isDirectory: true).standardizedFileURL
            var dirStat = stat()
            guard lstat(root.path, &dirStat) == 0,
                  dirStat.st_uid == getuid(),
                  (dirStat.st_mode & S_IFMT) == S_IFDIR else { continue }

            let summaries = readSummaries(in: root)
            let sessionHints = surface == .cli ? readSessionModelHints(matchingStorageRoot: root.path) : [:]
            let conversationIDs = discoverConversationIDs(in: root, summaries: summaries)

            for id in conversationIDs.prefix(Self.maxConversationsPerSurface) {
                let transcriptURL = root
                    .appendingPathComponent("brain", isDirectory: true)
                    .appendingPathComponent(id, isDirectory: true)
                    .appendingPathComponent(".system_generated/logs/transcript.jsonl")
                let cacheKey = "\(surface.rawValue):\(id)"
                var fileStat = stat()
                guard lstat(transcriptURL.path, &fileStat) == 0,
                      fileStat.st_uid == getuid(),
                      (fileStat.st_mode & S_IFMT) == S_IFREG,
                      fileStat.st_size >= 0 else { continue }

                activeCacheKeys.insert(cacheKey)
                let size = UInt64(fileStat.st_size)
                var state = fileCache[cacheKey]
                if let existing = state,
                   existing.device != fileStat.st_dev || existing.inode != fileStat.st_ino || size < existing.offset {
                    state = nil
                }
                var current = state ?? CachedTranscript(device: fileStat.st_dev, inode: fileStat.st_ino, offset: 0)

                var caughtUp = true
                let fileMTime = Date(
                    timeIntervalSince1970: Double(fileStat.st_mtimespec.tv_sec)
                        + Double(fileStat.st_mtimespec.tv_nsec) / 1_000_000_000
                )
                if size > current.offset {
                    if remainingBudget <= 0 {
                        caughtUp = false
                        allComplete = false
                    } else {
                        let previousTurn = current.turn
                        let outcome = advance(&current, from: transcriptURL, fileSize: size, budget: &remainingBudget)
                        caughtUp = outcome.caughtUp
                        if current.turn != previousTurn, current.turn.turnID != nil {
                            let boundedMTime = min(now, fileMTime)
                            current.turn.transcriptModifiedAt = max(current.turn.updatedAt, boundedMTime)
                        }
                        if !outcome.caughtUp || !current.complete {
                            allComplete = false
                        }
                    }
                } else if !current.complete {
                    allComplete = false
                }

                fileCache[cacheKey] = current
                sessionCount += 1
                lifetimeTokens = AntigravityMath.add(lifetimeTokens, current.totalTokens)
                allUnpriced.formUnion(current.unpricedModels)

                let summary = summaries[id]
                let resolvedSessionModel = current.model ?? sessionHints[id]

                for (day, acc) in current.days {
                    var merged = globalDays[day] ?? DayAccumulator()
                    merged.tokens = AntigravityMath.add(merged.tokens, acc.tokens)
                    merged.inputTokens = AntigravityMath.add(merged.inputTokens, acc.inputTokens)
                    merged.cacheReadTokens = AntigravityMath.add(merged.cacheReadTokens, acc.cacheReadTokens)
                    merged.outputTokens = AntigravityMath.add(merged.outputTokens, acc.outputTokens)
                    merged.knownCost += acc.knownCost
                    merged.hasUnpriced = merged.hasUnpriced || acc.hasUnpriced
                    globalDays[day] = merged
                }

                for (day, anon) in current.anonymousDays {
                    var merged = globalDays[day] ?? DayAccumulator()
                    if let hint = resolvedSessionModel,
                       let cost = AntigravityPricing.estimateCost(
                           model: hint,
                           inputTokens: anon.inputTokens,
                           cacheReadTokens: anon.cacheReadTokens,
                           outputTokens: anon.outputTokens,
                           at: anon.latestTimestamp > .distantPast ? anon.latestTimestamp : day
                       ) {
                        merged.knownCost += cost
                    } else {
                        merged.hasUnpriced = true
                        if let hint = resolvedSessionModel, !hint.isEmpty {
                            allUnpriced.insert(hint)
                        } else if let agent = summary?.agentName.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty {
                            allUnpriced.insert(agent)
                        }
                    }
                    globalDays[day] = merged
                }

                let isSubagent = summary?.isSubagent ?? false
                guard !isSubagent else { continue }

                let lockURL = root
                    .appendingPathComponent("presence", isDirectory: true)
                    .appendingPathComponent("\(id).lock")
                let isLocked = liveLockOverride?(id, surface) ?? Self.isExclusivelyLocked(lockURL)
                let summaryBusy = (summary?.killed != true) && (
                    summary?.notFullyIdle == true ||
                    (summary?.status.isEmpty == false && summary?.status != "CASCADE_RUN_STATUS_IDLE")
                )
                let summaryStatus: AntigravitySessionRecord.SummaryStatus = {
                    guard let summary else { return .unknown }
                    if summary.killed { return .killed }
                    if summary.status == "CASCADE_RUN_STATUS_CANCELING" { return .canceling }
                    if summary.notFullyIdle || summary.status == "CASCADE_RUN_STATUS_RUNNING" || summary.status == "CASCADE_RUN_STATUS_BUSY" {
                        return .running
                    }
                    if summary.status == "CASCADE_RUN_STATUS_IDLE" {
                        return .idle(modifiedAt: summary.modifiedAt)
                    }
                    return .unknown
                }()

                let rawTitle = summary?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = !rawTitle.isEmpty ? rawTitle : (!current.fallbackTitle.isEmpty ? current.fallbackTitle : surface.displayName + " 任务")
                let cwd = !(summary?.cwd.isEmpty ?? true) ? summary!.cwd : current.inferredCwd

                let record = AntigravitySessionRecord(
                    id: id,
                    surface: surface,
                    cwd: cwd,
                    title: String(title.prefix(160)),
                    model: resolvedSessionModel,
                    totalTokens: current.totalTokens,
                    isSubagent: false,
                    isLockedLive: isLocked,
                    summaryBusy: summaryBusy,
                    summaryStatus: summaryStatus,
                    caughtUp: caughtUp,
                    turn: current.turn
                )
                liveSessions.append(record)
            }
        }

        if fileCache.count > activeCacheKeys.count {
            fileCache = fileCache.filter { activeCacheKeys.contains($0.key) }
        }

        let sortedDays = globalDays.keys.sorted().map { date -> AntigravityUsageSummary.Day in
            let acc = globalDays[date]!
            return AntigravityUsageSummary.Day(
                date: date,
                tokens: acc.tokens,
                inputTokens: acc.inputTokens,
                cacheReadTokens: acc.cacheReadTokens,
                outputTokens: acc.outputTokens,
                knownCost: acc.knownCost,
                hasUnpriced: acc.hasUnpriced
            )
        }

        let usage = AntigravityUsageSummary(
            days: sortedDays,
            lifetimeTokens: lifetimeTokens,
            sessionCount: sessionCount,
            complete: allComplete,
            unpricedModels: allUnpriced.sorted(),
            updatedAt: now
        )
        return AntigravityScanResult(usage: usage, sessions: liveSessions)
    }

    // MARK: - Incremental JSONL Parsing

    private func advance(
        _ state: inout CachedTranscript,
        from url: URL,
        fileSize: UInt64,
        budget: inout Int
    ) -> (caughtUp: Bool, bytesRead: Int) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            state.complete = false
            return (false, 0)
        }
        defer { Darwin.close(descriptor) }

        var checkStat = stat()
        guard fstat(descriptor, &checkStat) == 0,
              checkStat.st_uid == getuid(),
              checkStat.st_dev == state.device,
              checkStat.st_ino == state.inode else {
            state.complete = false
            return (false, 0)
        }

        guard lseek(descriptor, off_t(state.offset), SEEK_SET) >= 0 else {
            state.complete = false
            return (false, 0)
        }

        let maxToRead = min(Int(fileSize - state.offset), budget)
        guard maxToRead > 0 else { return (state.offset >= fileSize, 0) }

        var carry = Data()
        var pendingLineBytes = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var totalRead = 0
        var consumedOffset = state.offset
        var droppingOversizedLine = false

        while totalRead < maxToRead {
            let chunkLimit = min(buffer.count, maxToRead - totalRead)
            let count = Darwin.read(descriptor, &buffer, chunkLimit)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            totalRead += count
            budget -= count

            var sliceStart = 0
            while sliceStart < count {
                let slice = buffer[sliceStart..<count]
                if let newlineIdx = slice.firstIndex(of: 0x0A) {
                    let pieceLength = newlineIdx - sliceStart
                    if !droppingOversizedLine {
                        if carry.count + pieceLength <= Self.maxLineBytes {
                            carry.append(contentsOf: buffer[sliceStart..<newlineIdx])
                            parseLine(carry, into: &state)
                        } else {
                            state.complete = false
                        }
                    }
                    carry.removeAll(keepingCapacity: true)
                    droppingOversizedLine = false
                    consumedOffset += UInt64(pendingLineBytes + pieceLength + 1)
                    pendingLineBytes = 0
                    sliceStart = newlineIdx + 1
                } else {
                    let remaining = count - sliceStart
                    pendingLineBytes += remaining
                    if !droppingOversizedLine {
                        if carry.count + remaining <= Self.maxLineBytes {
                            carry.append(contentsOf: buffer[sliceStart..<count])
                        } else {
                            carry.removeAll(keepingCapacity: true)
                            droppingOversizedLine = true
                            state.complete = false
                        }
                    }
                    break
                }
            }
        }

        state.offset = consumedOffset
        let caughtUp = carry.isEmpty && !droppingOversizedLine && state.offset >= fileSize
        return (caughtUp, totalRead)
    }

    private func parseLine(_ data: Data, into state: inout CachedTranscript) {
        guard !data.isEmpty else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            state.complete = false
            return
        }
        guard let type = object["type"] as? String else { return }
        let stepIndex = AntigravityMath.nonNegativeInt(object["step_index"])
        let timestamp = (object["created_at"] as? String).flatMap(FastTimestamp.parse) ?? Date()

        if type == "USER_INPUT" {
            let source = object["source"] as? String
            guard source == nil || source == "USER_EXPLICIT" else { return }
            let rawContent = object["content"] as? String ?? ""
            let cleanedUser = Self.cleanUserPrompt(rawContent)
            if state.fallbackTitle.isEmpty, !cleanedUser.isEmpty {
                state.fallbackTitle = String(cleanedUser.prefix(120))
            }
            if state.inferredCwd.isEmpty, let workspace = Self.extractWorkspace(from: rawContent) {
                state.inferredCwd = workspace
            }
            let turnID = stepIndex.map { "step-\($0)" } ?? "turn-\(Int(timestamp.timeIntervalSince1970))"
            state.pendingToolIndices.removeAll()
            state.turn = AntigravitySessionRecord.TurnSnapshot(
                turnID: turnID,
                phase: .working,
                startedAt: timestamp,
                updatedAt: timestamp,
                tokens: 0,
                text: cleanedUser.isEmpty ? "思考中" : String(cleanedUser.prefix(200)),
                steps: []
            )
            return
        }

        if type == "SYSTEM_MESSAGE",
           let stepIndex, stepIndex > 0,
           state.turn.turnID != nil,
           !state.turn.isActive {
            // Reactive wakeup from an async background task or subagent after the preceding turn settled.
            state.pendingToolIndices.removeAll()
            state.turn = AntigravitySessionRecord.TurnSnapshot(
                turnID: "step-\(stepIndex)",
                phase: .working,
                startedAt: timestamp,
                updatedAt: timestamp,
                tokens: 0,
                text: state.turn.text.isEmpty ? "思考中" : state.turn.text,
                steps: []
            )
            return
        }

        if type == "PLANNER_RESPONSE" {
            let isNewStep = stepIndex.map { state.seenSteps.insert($0).inserted } ?? true
            let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let model, !model.isEmpty {
                state.model = model
            }

            let inTokens = AntigravityMath.nonNegativeInt(object["input_tokens"]) ?? 0
            let cacheTokens = AntigravityMath.nonNegativeInt(object["cache_read_tokens"]) ?? 0
            let outTokens = AntigravityMath.nonNegativeInt(object["output_tokens"]) ?? 0
            let stepTokens = AntigravityMath.add(AntigravityMath.add(inTokens, cacheTokens), outTokens)

            if isNewStep && stepTokens > 0 {
                state.totalTokens = AntigravityMath.add(state.totalTokens, stepTokens)
                state.turn.tokens = AntigravityMath.add(state.turn.tokens, stepTokens)

                let day = calendar.startOfDay(for: timestamp)
                var acc = state.days[day] ?? DayAccumulator()
                acc.tokens = AntigravityMath.add(acc.tokens, stepTokens)
                acc.inputTokens = AntigravityMath.add(acc.inputTokens, inTokens)
                acc.cacheReadTokens = AntigravityMath.add(acc.cacheReadTokens, cacheTokens)
                acc.outputTokens = AntigravityMath.add(acc.outputTokens, outTokens)

                let modelKey = (model ?? state.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if modelKey.isEmpty {
                    var anon = state.anonymousDays[day] ?? AnonymousDayAccumulator()
                    anon.inputTokens = AntigravityMath.add(anon.inputTokens, inTokens)
                    anon.cacheReadTokens = AntigravityMath.add(anon.cacheReadTokens, cacheTokens)
                    anon.outputTokens = AntigravityMath.add(anon.outputTokens, outTokens)
                    anon.latestTimestamp = max(anon.latestTimestamp, timestamp)
                    state.anonymousDays[day] = anon
                } else if let cost = AntigravityPricing.estimateCost(
                    model: modelKey,
                    inputTokens: inTokens,
                    cacheReadTokens: cacheTokens,
                    outputTokens: outTokens,
                    at: timestamp
                ) {
                    acc.knownCost += cost
                } else {
                    acc.hasUnpriced = true
                    state.unpricedModels.insert(modelKey)
                }
                state.days[day] = acc
            }

            guard state.turn.turnID != nil else { return }
            state.turn.updatedAt = max(state.turn.updatedAt, timestamp)
            let status = (object["status"] as? String)?.uppercased() ?? "DONE"

            if status == "ERROR" {
                Self.settleActiveSteps(&state.turn.steps, as: "failed")
                state.pendingToolIndices.removeAll()
                state.turn.phase = .failed
                return
            }
            if status == "CANCELED" || status == "CANCELLED" {
                Self.settleActiveSteps(&state.turn.steps, as: "completed")
                state.pendingToolIndices.removeAll()
                state.turn.phase = .cancelled
                return
            }

            if let content = object["content"] as? String,
               let summary = Self.firstPublicLine(content) {
                state.turn.text = summary
            }

            let toolCalls = object["tool_calls"] as? [[String: Any]] ?? []
            if !toolCalls.isEmpty {
                state.pendingToolIndices.removeAll()
                var hasQuestion = false
                for (idx, call) in toolCalls.enumerated() {
                    let name = (call["name"] as? String) ?? "tool"
                    let isQuestion = name == "ask_question"
                    if isQuestion { hasQuestion = true }
                    let args = call["args"] as? [String: Any]
                    let title = Self.toolDisplayTitle(name: name, args: args)
                    let item = AntigravitySessionRecord.StepItem(
                        id: "s\(stepIndex ?? 0)-\(idx)",
                        title: title,
                        status: isQuestion ? "waiting" : "running"
                    )
                    state.pendingToolIndices.append(state.turn.steps.count)
                    state.turn.steps.append(item)
                    if state.turn.steps.count > 64 {
                        let overflow = state.turn.steps.count - 64
                        state.turn.steps.removeFirst(overflow)
                        state.pendingToolIndices = state.pendingToolIndices.compactMap { $0 >= overflow ? $0 - overflow : nil }
                    }
                }
                if hasQuestion {
                    state.turn.phase = .waitingQuestion
                    state.turn.text = "请在 Antigravity 中回答问题"
                } else {
                    state.turn.phase = .tool
                }
            } else if status == "DONE" {
                Self.settleActiveSteps(&state.turn.steps, as: "completed")
                state.pendingToolIndices.removeAll()
                state.turn.phase = .completed
            }
            return
        }

        if type == "GENERIC", state.turn.turnID != nil {
            state.turn.updatedAt = max(state.turn.updatedAt, timestamp)
            let status = (object["status"] as? String)?.uppercased() ?? "DONE"
            if !state.pendingToolIndices.isEmpty {
                let index = state.pendingToolIndices.removeFirst()
                if index >= 0 && index < state.turn.steps.count {
                    state.turn.steps[index].status = status == "ERROR" ? "failed" : "completed"
                }
            }
            if state.pendingToolIndices.isEmpty && (state.turn.phase == .tool || state.turn.phase == .waitingQuestion) {
                state.turn.phase = .working
            }
        }
    }

    private static func settleActiveSteps(_ steps: inout [AntigravitySessionRecord.StepItem], as status: String) {
        for index in steps.indices where steps[index].status == "running" || steps[index].status == "waiting" {
            steps[index].status = status
        }
    }

    // MARK: - Formatting & Extraction Helpers

    static func toolDisplayTitle(name: String, args: [String: Any]?) -> String {
        let summary = (args?["toolSummary"] as? String)
            ?? (args?["Description"] as? String)
            ?? (args?["Role"] as? String)
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return String(summary.prefix(80))
        }
        let cleaned = name
            .replacingOccurrences(of: "default_api:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch cleaned {
        case "run_command": return "执行命令"
        case "read_file", "view_file": return "读取文件"
        case "edit_file": return "编辑文件"
        case "write_file": return "写入文件"
        case "search_web": return "网页搜索"
        case "grep_search", "find_by_name": return "搜索代码"
        case "ask_question": return "等待用户回答"
        case "invoke_subagent": return "调用子代理"
        case "run_workflow": return "运行工作流"
        case "swarm": return "协同代理组"
        default:
            if cleaned.hasPrefix("browser_") { return "浏览器操作" }
            return String(cleaned.replacingOccurrences(of: "_", with: " ").prefix(48))
        }
    }

    private static func cleanUserPrompt(_ raw: String) -> String {
        var slice = raw[...]
        if let openRange = slice.range(of: "<USER_REQUEST>"),
           let closeRange = slice.range(of: "</USER_REQUEST>"),
           openRange.upperBound <= closeRange.lowerBound {
            slice = slice[openRange.upperBound..<closeRange.lowerBound]
        }
        return firstPublicLine(String(slice)) ?? ""
    }

    private static func extractWorkspace(from raw: String) -> String? {
        guard let marker = raw.range(of: "Command Working Directory:") else { return nil }
        let tail = raw[marker.upperBound...]
        guard let firstLine = tail.split(whereSeparator: \.isNewline).first else { return nil }
        let path = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? String(path.prefix(1_024)) : nil
    }

    private static func firstPublicLine(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("```") { continue }
            return String(trimmed.prefix(500))
        }
        return nil
    }

    // MARK: - SQLite Summary & Presence Lock Discovery

    private func discoverConversationIDs(in surfaceRoot: URL, summaries: [String: SummaryRow]) -> [String] {
        var ids = Set(summaries.keys)
        let brainURL = surfaceRoot.appendingPathComponent("brain", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: brainURL.path) {
            for entry in entries where entry.count <= 128 && !entry.hasPrefix(".") {
                ids.insert(entry)
            }
        }
        return ids.sorted()
    }

    private func readSummaries(in surfaceRoot: URL) -> [String: SummaryRow] {
        let dbURL = surfaceRoot.appendingPathComponent("conversation_summaries.db")
        var metadata = stat()
        guard lstat(dbURL.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size > 0 else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        _ = sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)

        let sql = """
        SELECT conversation_id, title, workspace_uris, status, nesting_depth, parent_conversation_id, not_fully_idle, killed, last_modified_time, agent_name
        FROM conversation_summaries
        ORDER BY last_modified_time DESC
        LIMIT 2048;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: SummaryRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idPtr)
            guard !id.isEmpty, id.utf8.count <= 128 else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let urisRaw = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let status = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            let depth = Int(sqlite3_column_int(statement, 4))
            let parent = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
            let notIdle = sqlite3_column_int(statement, 6) != 0
            let killed = sqlite3_column_int(statement, 7) != 0
            let modRaw = sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? ""
            let agentName = sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? ""

            result[id] = SummaryRow(
                id: id,
                title: title,
                cwd: Self.decodeWorkspacePath(urisRaw),
                status: status,
                agentName: agentName,
                isSubagent: depth > 0 || !parent.isEmpty,
                notFullyIdle: notIdle,
                killed: killed,
                modifiedAt: Self.parseSQLiteTimestamp(modRaw)
            )
        }
        return result
    }

    private func readSessionModelHints(matchingStorageRoot expectedRoot: String) -> [String: String] {
        guard let cacheDir = statusLineCacheDirectory else { return [:] }
        var dirStat = stat()
        guard lstat(cacheDir.path, &dirStat) == 0,
              dirStat.st_uid == getuid(),
              (dirStat.st_mode & S_IFMT) == S_IFDIR else { return [:] }

        var hints: [String: String] = [:]

        // 1. Per-session usage cache (`usage/<conversation_id>.json`)
        let usageDir = cacheDir.appendingPathComponent("usage", isDirectory: true)
        if let usageFiles = try? FileManager.default.contentsOfDirectory(at: usageDir, includingPropertiesForKeys: nil) {
            for file in usageFiles where file.pathExtension == "json" {
                guard let obj = Self.readSmallOwnedJSONObject(file) else { continue }
                let storageRoot = (obj["storage_root"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                guard storageRoot == nil || storageRoot == expectedRoot else { continue }
                let id = ((obj["conversation_id"] as? String) ?? file.deletingPathExtension().lastPathComponent)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let model = ((obj["model_id"] as? String) ?? (obj["model"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty, let model, !model.isEmpty {
                    hints[id] = model
                }
            }
        }

        // 2. Live process snapshots (`<pid>.json`)
        if let liveFiles = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in liveFiles where file.pathExtension == "json" {
                guard let obj = Self.readSmallOwnedJSONObject(file) else { continue }
                let storageRoot = (obj["storage_root"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                guard storageRoot == nil || storageRoot == expectedRoot else { continue }
                guard let facts = obj["facts"] as? [String: Any] else { continue }
                let id = (facts["conversation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let model = ((facts["model_id"] as? String) ?? (facts["model"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty, let model, !model.isEmpty {
                    hints[id] = model
                }
            }
        }

        return hints
    }

    private static func readSmallOwnedJSONObject(_ url: URL) -> [String: Any]? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              st.st_uid == getuid(),
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0,
              st.st_size <= 65_536 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(st.st_size))
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(buffer.prefix(count)))) as? [String: Any]
    }

    static func parseSQLiteTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 19, !trimmed.hasPrefix("0001-") else { return nil }
        if let direct = FastTimestamp.parse(trimmed) { return direct }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 10)
        if trimmed[idx] == " " {
            var iso = trimmed
            iso.replaceSubrange(idx...idx, with: "T")
            if let parsed = FastTimestamp.parse(iso) { return parsed }
        }
        return nil
    }

    static func decodeWorkspacePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
           let first = array.first as? String {
            return resolveURIOrPath(first)
        }
        return resolveURIOrPath(trimmed)
    }

    private static func resolveURIOrPath(_ raw: String) -> String {
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return url.path
        }
        if raw.hasPrefix("/") {
            return raw
        }
        return ""
    }

    static func isExclusivelyLocked(_ url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              st.st_uid == getuid(),
              (st.st_mode & S_IFMT) == S_IFREG else { return false }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }
}
