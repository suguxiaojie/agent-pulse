import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class AntigravityRuntime: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var hooksEnabled: Bool
    @Published private(set) var statusLineEnabled: Bool
    @Published private(set) var configuring = false
    @Published private(set) var status = "未启用"
    @Published private(set) var error: String?
    @Published private(set) var quota: AntigravityQuotaSnapshot?
    @Published private(set) var usage: AntigravityUsageSummary?
    @Published private(set) var rows: [ActivitySessionSnapshot] = []
    @Published private(set) var installation: AntigravityInstallationStatus
    @Published private(set) var scanning = false

    var onRowsChanged: (() -> Void)?
    let installer: AntigravityInstaller

    private let defaults: UserDefaults
    private let bridge: ClaudeCodeBridge
    private let scanner: AntigravityScanner
    private let configurationQueue: DispatchQueue
    private var bridgeListening = false
    private var bridgeGeneration = UUID()
    private var generation = UUID()
    private var running = false
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var desiredConfiguration: (enabled: Bool, hooks: Bool, statusLine: Bool)?
    private var bufferedHooks: [(message: ClaudeCodeBridgeMessage, receivedAt: Date)] = []

    private struct HookOverlay {
        var surface: AntigravitySurface
        var cwd: String = ""
        var title: String = ""
        var model: String?
        var phase: TaskPhase?
        var endReason: SessionEndReason?
        var actionText: String = ""
        var startedAt: Date?
        var updatedAt = Date.distantPast
        var hookProcessID: pid_t?
        var steps: [IslandStep] = []
        var turnIndex: Int = 0
    }

    private var hookOverlays: [String: HookOverlay] = [:]
    private var sessionSurfaces: [String: AntigravitySurface] = [:]
    private var observedActiveTurns: Set<String> = []
    private var settledTurns: [String: (phase: TaskPhase, endReason: SessionEndReason, settledAt: Date)] = [:]
    private var receipts: [String: ActivitySessionSnapshot] = [:]
    private var lastScan: AntigravityScanResult?
    private var lastStatusLineFileMTime: TimeInterval = 0
    private var lastOneNativeStatusLineMTime: TimeInterval = 0
    private var pendingManualRefresh = false

    init(
        defaults: UserDefaults = .standard,
        installer: AntigravityInstaller? = nil,
        scanner: AntigravityScanner? = nil,
        installation: AntigravityInstallationStatus? = nil,
        configurationQueue: DispatchQueue = DispatchQueue(label: "com.coverai.codex-pulse.antigravity.configuration")
    ) {
        self.defaults = defaults
        self.configurationQueue = configurationQueue
        self.enabled = defaults.bool(forKey: "antigravity.enabled")
        self.hooksEnabled = defaults.object(forKey: "antigravity.hooks") as? Bool ?? true
        self.statusLineEnabled = defaults.object(forKey: "antigravity.statusLine") as? Bool ?? true

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexNotchMonitor/Antigravity", isDirectory: true)
        let resolvedInstaller = installer ?? AntigravityInstaller(
            socketURL: base.appendingPathComponent("bridge.sock"),
            authenticationToken: UUID().uuidString + UUID().uuidString
        )
        self.installer = resolvedInstaller
        self.bridge = ClaudeCodeBridge(
            socketURL: resolvedInstaller.socketURL,
            authenticationToken: resolvedInstaller.authenticationToken
        )
        self.scanner = scanner ?? AntigravityScanner(geminiDirectory: resolvedInstaller.geminiDirectory)
        self.installation = installation ?? AntigravityInstallationStatus.detect()
    }

    func start() {
        guard !running else { return }
        running = true
        refreshInstallation()
        if enabled {
            configure(enabled: true, hooks: hooksEnabled, statusLine: statusLineEnabled, startup: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        running = false
        generation = UUID()
        timer?.invalidate()
        timer = nil
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        configuring = false
        desiredConfiguration = nil
        stopBridge()
        bufferedHooks.removeAll()
        hookOverlays.removeAll()
        sessionSurfaces.removeAll()
        settledTurns.removeAll()
        receipts.removeAll()
        rows = []
        onRowsChanged?()
    }

    func refreshInstallation() {
        installation = AntigravityInstallationStatus.detect()
    }

    func retry() {
        if let desiredConfiguration {
            configure(
                enabled: desiredConfiguration.enabled,
                hooks: desiredConfiguration.hooks,
                statusLine: desiredConfiguration.statusLine
            )
        } else {
            configure(enabled: enabled, hooks: hooksEnabled, statusLine: statusLineEnabled)
        }
    }

    func refresh() {
        refreshInstallation()
        if enabled && statusLineEnabled {
            loadPersistedStatusLineSnapshot(force: true)
        }
        pendingManualRefresh = true
        refreshActivity(manual: true)
    }

    func configure(enabled target: Bool, hooks: Bool, statusLine: Bool, startup: Bool = false) {
        guard !configuring else { return }
        desiredConfiguration = (target, hooks, statusLine)
        configuring = true
        error = nil
        status = "配置中"
        generation = UUID()
        let configGeneration = generation
        scanTask?.cancel()
        scanTask = nil
        scanning = false

        if !target || !statusLine {
            quota = nil
        }
        if target && running && (hooks || statusLine) {
            do { try startBridge() } catch { self.error = error.localizedDescription }
        } else if !target || (!hooks && !statusLine) {
            stopBridge()
            bufferedHooks.removeAll()
        }

        let installer = installer
        configurationQueue.async { [weak self] in
            let result: Result<Void, Error> = Result {
                if target && (hooks || statusLine) {
                    try installer.install(.init(hooks: hooks, statusLine: statusLine))
                } else {
                    try installer.uninstall()
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == configGeneration else { return }
                self.configuring = false
                switch result {
                case .failure(let failure):
                    self.status = "需要处理"
                    self.error = failure.localizedDescription
                    self.bufferedHooks.removeAll()
                    self.stopBridge()
                    if !startup {
                        self.quota = nil
                        self.hookOverlays.removeAll()
                        self.rows = []
                        self.onRowsChanged?()
                    }
                case .success:
                    self.enabled = target
                    self.hooksEnabled = hooks
                    self.statusLineEnabled = statusLine
                    self.defaults.set(target, forKey: "antigravity.enabled")
                    self.defaults.set(hooks, forKey: "antigravity.hooks")
                    self.defaults.set(statusLine, forKey: "antigravity.statusLine")
                    if !target {
                        self.usage = nil
                        self.quota = nil
                        self.hookOverlays.removeAll()
                        self.sessionSurfaces.removeAll()
                        self.observedActiveTurns.removeAll()
                        self.settledTurns.removeAll()
                        self.receipts.removeAll()
                        self.lastScan = nil
                        self.rows = []
                        self.status = "未启用"
                        self.onRowsChanged?()
                        return
                    }
                    if self.running && (hooks || statusLine) {
                        do {
                            try self.startBridge()
                            self.error = nil
                        } catch {
                            self.status = "需要处理"
                            self.error = error.localizedDescription
                        }
                    }
                    self.status = self.connectionStatusSummary()
                    self.loadPersistedStatusLineSnapshot(force: true)
                    if !statusLine {
                        self.quota = nil
                    }
                    let pending = self.bufferedHooks
                    self.bufferedHooks.removeAll()
                    for item in pending {
                        self.receive(item.message, receivedAt: item.receivedAt)
                    }
                    self.refreshActivity()
                }
            }
        }
    }

    private func connectionStatusSummary() -> String {
        guard enabled else { return "未启用" }
        var parts: [String] = []
        if hooksEnabled { parts.append("三端 Hook 已就绪") }
        if statusLineEnabled { parts.append("CLI 状态栏已就绪") }
        if parts.isEmpty { parts.append("仅本地日志只读扫描") }
        return parts.joined(separator: " · ")
    }

    private func startBridge() throws {
        guard !bridgeListening else { return }
        let epoch = UUID()
        bridgeGeneration = epoch
        try bridge.start(onMessage: { [weak self] message in
            let receivedAt = Date()
            Task { @MainActor in
                guard let self, self.bridgeGeneration == epoch, self.running else { return }
                self.receive(message, receivedAt: receivedAt)
            }
        }, onDisconnect: { _ in })
        bridgeListening = true
    }

    private func stopBridge() {
        bridgeGeneration = UUID()
        bridgeListening = false
        bridge.stop()
    }

    private func loadPersistedStatusLineSnapshot(force: Bool = false) {
        let uid = getuid()
        var pulseMTime: TimeInterval = 0
        var st = stat()
        if lstat(installer.statusLineSnapshotURL.path, &st) == 0,
           st.st_uid == uid,
           (st.st_mode & S_IFMT) == S_IFREG {
            pulseMTime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
        }

        let oneNativeFiles = discoverOneNativeStatusLineFiles(uid: uid)
        let oneNativeMaxMTime = oneNativeFiles.map(\.mtime).max() ?? 0

        guard force
            || pulseMTime > lastStatusLineFileMTime
            || oneNativeMaxMTime > lastOneNativeStatusLineMTime
            || quota == nil else { return }

        lastStatusLineFileMTime = max(lastStatusLineFileMTime, pulseMTime)
        lastOneNativeStatusLineMTime = max(lastOneNativeStatusLineMTime, oneNativeMaxMTime)

        let pulseSnapshot: AntigravityQuotaSnapshot? = {
            guard pulseMTime > 0,
                  let data = Self.readPrivateRegularFile(
                      installer.statusLineSnapshotURL,
                      uid: uid,
                      requirePrivateMode: false,
                      maxBytes: 262_144
                  ) else { return nil }
            return AntigravityQuotaSnapshot.decode(snapshot: data)
        }()

        var newestOneNative: AntigravityQuotaSnapshot?
        let now = Date()
        var overlayChanged = false
        for item in oneNativeFiles.sorted(by: { $0.mtime > $1.mtime }) {
            guard let data = Self.readPrivateRegularFile(item.url, uid: uid, requirePrivateMode: true, maxBytes: 65_536) else { continue }
            if let rawObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if ingestOneNativeLiveOverlay(rawObj, now: now) {
                    overlayChanged = true
                }
            }
            guard let decoded = AntigravityQuotaSnapshot.decode(snapshot: data) else { continue }
            if newestOneNative == nil || decoded.capturedAt > newestOneNative!.capturedAt {
                newestOneNative = decoded
            }
        }

        let candidate: AntigravityQuotaSnapshot?
        switch (pulseSnapshot, newestOneNative) {
        case let (.some(pulse), .some(oneNative)):
            if oneNative.capturedAt >= pulse.capturedAt {
                candidate = oneNative.mergingMetadata(from: pulse)
            } else {
                candidate = pulse.mergingMetadata(from: oneNative)
            }
        case let (.some(pulse), .none):
            candidate = pulse
        case let (.none, .some(oneNative)):
            candidate = oneNative.mergingMetadata(from: quota)
        case (.none, .none):
            candidate = nil
        }

        if statusLineEnabled,
           let candidate,
           force || candidate.capturedAt >= (quota?.capturedAt ?? .distantPast) || quota == nil {
            quota = candidate.mergingMetadata(from: quota)
        }

        if overlayChanged {
            if let lastScan {
                projectRows(lastScan, now: now)
            } else {
                projectHookOnlyRows(now: now)
            }
        }
    }

    private func clearSettledTurns(forConversationID id: String, olderThan cutoff: Date? = nil) {
        let prefix = "agy:\(id):"
        for (key, entry) in settledTurns where key.hasPrefix(prefix) {
            if let cutoff {
                if entry.settledAt < cutoff {
                    settledTurns.removeValue(forKey: key)
                }
            } else {
                settledTurns.removeValue(forKey: key)
            }
        }
    }

    private func ingestOneNativeLiveOverlay(_ object: [String: Any], now: Date) -> Bool {
        guard let facts = object["facts"] as? [String: Any],
              let id = (facts["conversation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, id.utf8.count <= 256 else { return false }
        let pidNum = (object["pid"] as? Int) ?? 0
        guard pidNum > 1 else { return false }
        let pid = pid_t(pidNum)
        let alive = Self.isProcessAlive(pid)
        let observedAt = (object["observed_at"] as? String).flatMap(FastTimestamp.parse)
            ?? Date(timeIntervalSince1970: 0)
        guard observedAt > Date(timeIntervalSince1970: 1_000_000_000),
              observedAt <= now.addingTimeInterval(60) else { return false }

        let agentState = (facts["agent_state"] as? String)?.lowercased() ?? ""
        var overlay = hookOverlays[id] ?? HookOverlay(surface: .cli)
        let beforePhase = overlay.phase
        let beforeModel = overlay.model
        let beforeCwd = overlay.cwd

        if let cwd = facts["cwd"] as? String, !cwd.isEmpty {
            overlay.cwd = cwd
        }
        if let model = (facts["model_id"] as? String) ?? (facts["model"] as? String), !model.isEmpty {
            overlay.model = model
        }
        if let title = facts["conversation_title"] as? String, !title.isEmpty, overlay.title.isEmpty {
            overlay.title = title
        }

        if agentState == "working", alive, now.timeIntervalSince(observedAt) <= 30 {
            clearSettledTurns(forConversationID: id, olderThan: observedAt.addingTimeInterval(-0.5))
            overlay.hookProcessID = pid
            overlay.endReason = nil
            if overlay.phase == nil || overlay.phase?.isActive != true {
                overlay.turnIndex += 1
                overlay.startedAt = overlay.startedAt ?? observedAt
                overlay.phase = .working
            }
            overlay.updatedAt = max(overlay.updatedAt, observedAt)
            hookOverlays[id] = overlay
            return beforePhase != overlay.phase || beforeModel != overlay.model || beforeCwd != overlay.cwd
        } else if agentState == "idle" || !alive {
            if overlay.phase?.isActive == true, observedAt >= overlay.updatedAt.addingTimeInterval(-1) {
                overlay.phase = nil
                overlay.updatedAt = max(overlay.updatedAt, observedAt)
                hookOverlays[id] = overlay
                return true
            }
        }
        return false
    }

    private func discoverOneNativeStatusLineFiles(uid: uid_t) -> [(url: URL, mtime: TimeInterval)] {
        var results: [(url: URL, mtime: TimeInterval)] = []
        for directory in installer.oneNativeStatusLineDirectories {
            var dirStat = stat()
            guard lstat(directory.path, &dirStat) == 0,
                  (dirStat.st_mode & S_IFMT) == S_IFDIR,
                  dirStat.st_uid == uid,
                  (dirStat.st_mode & 0o077) == 0,
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                continue
            }
            for name in entries.prefix(64) where name.hasSuffix(".json") && !name.hasPrefix(".") {
                let stem = String(name.dropLast(5))
                guard Int32(stem) != nil else { continue }
                let fileURL = directory.appendingPathComponent(name)
                var fileStat = stat()
                guard lstat(fileURL.path, &fileStat) == 0,
                      (fileStat.st_mode & S_IFMT) == S_IFREG,
                      fileStat.st_uid == uid,
                      (fileStat.st_mode & 0o077) == 0,
                      fileStat.st_size > 0,
                      fileStat.st_size <= 65_536 else { continue }
                let mtime = Double(fileStat.st_mtimespec.tv_sec) + Double(fileStat.st_mtimespec.tv_nsec) / 1_000_000_000
                results.append((fileURL, mtime))
            }
        }
        return results
    }

    private static func readPrivateRegularFile(
        _ url: URL,
        uid: uid_t,
        requirePrivateMode: Bool,
        maxBytes: Int
    ) -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == uid,
              (!requirePrivateMode || (info.st_mode & 0o077) == 0),
              info.st_size > 0,
              info.st_size <= maxBytes else { return nil }
        var data = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maxBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.count <= maxBytes && !data.isEmpty ? data : nil
    }

    // MARK: - Incoming Helper Events

    func receive(_ message: ClaudeCodeBridgeMessage, receivedAt: Date = Date()) {
        guard (configuring ? desiredConfiguration?.enabled == true : enabled),
              let object = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any] else {
            bridge.resolve(eventID: message.eventID, decision: nil)
            return
        }
        bridge.resolve(eventID: message.eventID, decision: nil)

        if message.kind == "statusLine" {
            guard configuring ? desiredConfiguration?.statusLine == true : statusLineEnabled else { return }
            if let decoded = AntigravityQuotaSnapshot.decode(object: object, fallbackDate: receivedAt) {
                quota = decoded.mergingMetadata(from: quota)
            }
            if let sessionID = object["session_id"] as? String ?? object["sessionId"] as? String,
               !sessionID.isEmpty {
                var overlay = hookOverlays[sessionID] ?? HookOverlay(surface: .cli)
                if let modelObj = object["model"] as? [String: Any],
                   let modelID = (modelObj["id"] as? String) ?? (modelObj["display_name"] as? String),
                   !modelID.isEmpty {
                    overlay.model = modelID
                }
                if let agentState = (object["agent_state"] as? String ?? object["agentState"] as? String)?.lowercased() {
                    if agentState == "working" {
                        clearSettledTurns(forConversationID: sessionID, olderThan: receivedAt.addingTimeInterval(-0.5))
                        overlay.endReason = nil
                        if overlay.phase != .waitingApproval {
                            overlay.phase = .working
                        }
                        overlay.updatedAt = receivedAt
                    } else if agentState == "idle", overlay.phase?.isActive == true {
                        overlay.phase = nil
                        overlay.updatedAt = receivedAt
                    }
                }
                hookOverlays[sessionID] = overlay
                if let lastScan { projectRows(lastScan, now: receivedAt) }
            }
            return
        }

        guard configuring ? desiredConfiguration?.hooks == true : hooksEnabled else { return }
        if configuring {
            if bufferedHooks.count >= 256 { bufferedHooks.removeFirst() }
            bufferedHooks.append((message, receivedAt))
            return
        }

        guard let id = object["conversationId"] as? String, !id.isEmpty, id.utf8.count <= 256,
              let event = object["hookEventName"] as? String else { return }

        status = "已连接"
        let transcriptPath = object["transcriptPath"] as? String ?? ""
        let surface = Self.detectSurface(from: transcriptPath)
        var overlay = hookOverlays[id] ?? HookOverlay(surface: surface)
        overlay.surface = surface
        overlay.updatedAt = receivedAt

        if let cwd = object["cwd"] as? String, !cwd.isEmpty {
            overlay.cwd = cwd
        } else if let paths = object["workspacePaths"] as? [String], let first = paths.first, !first.isEmpty {
            overlay.cwd = first
        }
        if let model = object["modelName"] as? String, !model.isEmpty, model != "auto" {
            overlay.model = model
        }
        if let pidNum = object["hookProcessId"] as? Int, pidNum > 1 {
            let pid = pid_t(pidNum)
            if Self.isProcessAlive(pid) {
                overlay.hookProcessID = pid
            }
        }
        if let userInput = object["lastUserInput"] as? String, !userInput.isEmpty {
            overlay.title = userInput
        }

        switch event {
        case "SessionStart":
            hookOverlays[id] = overlay
            return

        case "PreInvocation":
            clearSettledTurns(forConversationID: id)
            let invNum = (object["invocationNum"] as? Int) ?? 0
            if invNum <= 1 || overlay.phase == nil || overlay.endReason != nil {
                overlay.turnIndex += 1
                overlay.startedAt = receivedAt
                overlay.steps.removeAll()
                overlay.endReason = nil
            }
            overlay.phase = .working
            if overlay.actionText.isEmpty || overlay.endReason != nil {
                overlay.actionText = overlay.title.isEmpty ? "思考中" : overlay.title
            }
            hookOverlays[id] = overlay

        case "PostToolUse":
            clearSettledTurns(forConversationID: id)
            overlay.endReason = nil
            overlay.phase = .working
            if let tool = object["toolCall"] as? [String: Any],
               let name = tool["name"] as? String {
                let stepID = (tool["id"] as? String) ?? "hook-\(overlay.steps.count)"
                let summary = (tool["summary"] as? String)
                let title = AntigravityScanner.toolDisplayTitle(
                    name: name,
                    args: summary.map { ["toolSummary": $0] }
                )
                let failed = (object["error"] as? String)?.isEmpty == false
                let state: IslandStep.State = failed ? .failed : .done
                if let idx = overlay.steps.firstIndex(where: { $0.id == stepID }) {
                    overlay.steps[idx].state = state
                } else {
                    overlay.steps.append(.init(id: stepID, title: title, state: state))
                    if overlay.steps.count > 32 { overlay.steps.removeFirst(overlay.steps.count - 32) }
                }
            }
            hookOverlays[id] = overlay
            refreshActivity()

        case "PostInvocation":
            clearSettledTurns(forConversationID: id)
            if overlay.endReason == nil {
                overlay.phase = .working
            }
            hookOverlays[id] = overlay

        case "Stop":
            let reason = (object["terminationReason"] as? String) ?? "NO_TOOL_CALL"
            overlay.steps = overlay.steps.map { $0.endingTask() }
            let terminalPhase: TaskPhase
            let terminalEnd: SessionEndReason
            switch reason {
            case "USER_CANCELED":
                terminalPhase = .ended
                terminalEnd = .cancelled
            case "ERROR", "MAX_INVOCATIONS", "MAX_FORCED_INVOCATIONS", "MAX_TOKEN_BUDGET_EXCEEDED":
                terminalPhase = .failed
                terminalEnd = .failed
            default:
                terminalPhase = .completed
                terminalEnd = .completed
            }
            overlay.phase = terminalPhase
            overlay.endReason = terminalEnd
            hookOverlays[id] = overlay
            if let existingTurn = rows.first(where: { $0.id == "agy:" + id })?.turnID {
                settledTurns["agy:\(id):\(existingTurn)"] = (terminalPhase, terminalEnd, receivedAt)
            }
            refreshActivity()

        default:
            break
        }

        if let lastScan {
            projectRows(lastScan, now: receivedAt)
        } else {
            projectHookOnlyRows(now: receivedAt)
        }
    }

    // MARK: - Periodic Scan & Projection

    private func tick() {
        guard enabled, !configuring else { return }
        loadPersistedStatusLineSnapshot()
        pruneExpiredReceipts(now: Date())
        refreshActivity()
    }

    func refreshActivity(manual: Bool = false) {
        guard enabled, !configuring, scanTask == nil else { return }
        let forceManual = manual || pendingManualRefresh
        pendingManualRefresh = false
        scanning = true
        let version = generation
        let scanner = scanner
        scanTask = Task(priority: forceManual ? .userInitiated : .utility) { [weak self] in
            let scan = await scanner.scan()
            guard let self, !Task.isCancelled, self.enabled, self.generation == version else { return }
            self.scanning = false
            self.scanTask = nil
            self.consume(scan, forcePublishUsage: forceManual)
            if self.pendingManualRefresh {
                self.refreshActivity(manual: true)
            }
        }
    }

    func consume(_ scan: AntigravityScanResult, now: Date = Date(), forcePublishUsage: Bool = false) {
        guard enabled else { return }
        lastScan = scan
        if forcePublishUsage || usage.map({ !$0.hasSameContent(as: scan.usage) }) ?? true {
            usage = scan.usage
        }
        projectRows(scan, now: now)
    }

    private func projectRows(_ scan: AntigravityScanResult, now: Date = Date()) {
        pruneExpiredReceipts(now: now)
        var next: [ActivitySessionSnapshot] = []
        var handledIDs: Set<String> = []

        for session in scan.sessions where session.caughtUp {
            handledIDs.insert(session.id)
            let rowID = "agy:" + session.id
            sessionSurfaces[rowID] = session.surface
            let overlay = hookOverlays[session.id]

            let hookAlive = overlay.map { ov in
                now.timeIntervalSince(ov.updatedAt) <= 30 && (ov.hookProcessID.map(Self.isProcessAlive) ?? true)
            } ?? false
            let live = session.isLockedLive || hookAlive

            let turn = session.turn
            let resolvedTurnID = turn.turnID ?? overlay.map { "hook-\($0.turnIndex)" }
            guard let turnID = resolvedTurnID else { continue }
            let turnKey = "\(rowID):\(turnID)"
            let previous = rows.first { $0.id == rowID && $0.turnID == turnID }

            var phase: TaskPhase
            var endReason: SessionEndReason?
            var waitReason: CodexActivityWaitReason?
            var replyIDs: Set<String> = []

            let summaryStopped: SessionEndReason? = {
                switch session.summaryStatus {
                case .killed:
                    return .ended
                case .canceling:
                    return .cancelled
                case .idle(let modifiedAt):
                    if let modifiedAt, modifiedAt >= turn.updatedAt.addingTimeInterval(-0.5) {
                        return .cancelled
                    }
                    if now.timeIntervalSince(turn.updatedAt) >= 2.0 {
                        return .cancelled
                    }
                    return nil
                case .running, .unknown:
                    return nil
                }
            }()

            if let existingSettled = settledTurns[turnKey] {
                let resumedByTranscript = (turn.isActive || session.summaryStatus == .running)
                    && turn.updatedAt > existingSettled.settledAt.addingTimeInterval(0.5)
                let resumedByOverlay = live
                    && overlay?.phase?.isActive == true
                    && (overlay?.updatedAt ?? .distantPast) > existingSettled.settledAt.addingTimeInterval(0.5)
                if resumedByTranscript || resumedByOverlay {
                    settledTurns.removeValue(forKey: turnKey)
                }
            }

            let activeOverlayNewerThanTurn = live
                && overlay?.phase?.isActive == true
                && (overlay?.updatedAt ?? .distantPast) > turn.updatedAt.addingTimeInterval(0.5)

            if let settled = settledTurns[turnKey] {
                phase = settled.phase
                endReason = settled.endReason
            } else if turn.isActive, let stopReason = summaryStopped, !activeOverlayNewerThanTurn {
                phase = .ended
                endReason = stopReason
                settledTurns[turnKey] = (phase, stopReason, now)
            } else if let ov = overlay, ov.updatedAt > turn.updatedAt, let ovPhase = ov.phase {
                if ovPhase.isActive && !live {
                    phase = .ended
                    endReason = .ended
                    settledTurns[turnKey] = (.ended, .ended, now)
                } else if ovPhase.isActive && live && turn.phase == .waitingQuestion {
                    phase = .waitingApproval
                    endReason = nil
                    waitReason = .userInput
                    replyIDs = ["\(turnKey):question"]
                } else if ovPhase.isActive && live && turn.phase == .tool {
                    phase = .usingTool
                    endReason = nil
                } else {
                    phase = ovPhase
                    endReason = ov.endReason
                    if let er = ov.endReason {
                        settledTurns[turnKey] = (ovPhase, er, ov.updatedAt)
                    }
                }
            } else {
                switch turn.phase {
                case .working:
                    phase = live ? .working : .ended
                    endReason = live ? nil : .ended
                case .tool:
                    phase = live ? .usingTool : .ended
                    endReason = live ? nil : .ended
                case .waitingQuestion:
                    phase = live ? .waitingApproval : .ended
                    endReason = live ? nil : .ended
                    if live {
                        waitReason = .userInput
                        replyIDs = ["\(turnKey):question"]
                    }
                case .completed:
                    phase = .completed
                    endReason = .completed
                case .failed:
                    phase = .failed
                    endReason = .failed
                case .cancelled:
                    phase = .ended
                    endReason = .cancelled
                case .idle:
                    continue
                }
            }

            let wasObservedActive = observedActiveTurns.contains(turnKey)
            let existingReceipt = receipts[rowID]
            guard (live && phase.isActive) || previous?.phase.isActive == true || existingReceipt != nil || (wasObservedActive && endReason != nil) else {
                continue
            }

            let cwd = !session.cwd.isEmpty ? session.cwd : (overlay?.cwd ?? "")
            let projectName = cwd.isEmpty ? session.surface.shortName : URL(fileURLWithPath: cwd).lastPathComponent
            let rawModel = session.model ?? overlay?.model
            let formattedModel = AntigravityPricing.formatModel(rawModel)

            let transcriptSteps = turn.steps.map { step -> IslandStep in
                let state: IslandStep.State
                switch step.status {
                case "completed": state = .done
                case "failed": state = .failed
                case "waiting": state = endReason != nil ? .ended : .waiting
                default: state = endReason != nil ? .ended : .running
                }
                return IslandStep(id: step.id, title: step.title, state: state)
            }
            let mergedSteps = IslandStep.visibleSteps(from: transcriptSteps.isEmpty ? (overlay?.steps ?? []) : transcriptSteps)

            let actionText: String
            if phase == .waitingApproval {
                actionText = "请在 \(session.surface.displayName) 中回答问题"
            } else if endReason == .cancelled {
                actionText = "已取消"
            } else if !turn.text.isEmpty {
                actionText = turn.text
            } else if let ovText = overlay?.actionText, !ovText.isEmpty {
                actionText = ovText
            } else {
                actionText = phase.title
            }

            let updatedAt: Date
            if endReason == nil {
                updatedAt = max(turn.updatedAt, overlay?.updatedAt ?? .distantPast)
            } else if let prevReceipt = existingReceipt, prevReceipt.turnID == turnID, prevReceipt.endReason != nil {
                updatedAt = prevReceipt.updatedAt
            } else if let previous, previous.endReason != nil {
                updatedAt = previous.updatedAt
            } else {
                updatedAt = settledTurns[turnKey]?.settledAt ?? now
            }

            var row = ActivitySessionSnapshot(
                sessionID: rowID,
                turnID: turnID,
                projectID: "agy:" + (cwd.isEmpty ? session.surface.rawValue : cwd),
                projectName: projectName,
                title: session.title,
                phase: phase,
                actionText: actionText,
                updatedAt: updatedAt == .distantPast ? now : updatedAt,
                tokenUsage: turn.tokens > 0 ? TurnTokenUsage(sessionID: rowID, turnID: turnID, total: turn.tokens, isCompleted: endReason != nil) : nil,
                endReason: endReason,
                modelName: formattedModel.model.isEmpty ? rawModel : formattedModel.model,
                reasoningEffort: formattedModel.effort,
                startedAt: turn.startedAt ?? overlay?.startedAt,
                sessionTotalTokens: session.totalTokens > 0 ? session.totalTokens : nil,
                provider: "Antigravity",
                waitReason: waitReason,
                replyRequestIDs: replyIDs,
                suppressCompletion: !wasObservedActive,
                recentSteps: mergedSteps
            )

            if phase.isActive {
                observedActiveTurns.insert(turnKey)
                receipts.removeValue(forKey: rowID)
                next.append(row)
            } else if wasObservedActive {
                let retainThreshold: TimeInterval = row.phase == .completed ? 15 : 6
                row.isRetainedReceipt = now.timeIntervalSince(row.updatedAt) >= retainThreshold
                receipts[rowID] = row
                if now.timeIntervalSince(row.updatedAt) < 60 {
                    next.append(row)
                } else {
                    receipts.removeValue(forKey: rowID)
                }
            }
        }

        // Handle hook-only sessions whose transcript file has not flushed its first step yet.
        for (id, overlay) in hookOverlays where !handledIDs.contains(id) {
            guard let phase = overlay.phase, phase.isActive,
                  now.timeIntervalSince(overlay.updatedAt) <= 30,
                  overlay.hookProcessID.map(Self.isProcessAlive) ?? true else { continue }
            let rowID = "agy:" + id
            sessionSurfaces[rowID] = overlay.surface
            let turnID = "hook-\(overlay.turnIndex)"
            let turnKey = "\(rowID):\(turnID)"
            observedActiveTurns.insert(turnKey)
            receipts.removeValue(forKey: rowID)
            let formattedModel = AntigravityPricing.formatModel(overlay.model)
            let projectName = overlay.cwd.isEmpty ? overlay.surface.shortName : URL(fileURLWithPath: overlay.cwd).lastPathComponent
            let row = ActivitySessionSnapshot(
                sessionID: rowID,
                turnID: turnID,
                projectID: "agy:" + (overlay.cwd.isEmpty ? overlay.surface.rawValue : overlay.cwd),
                projectName: projectName,
                title: overlay.title.isEmpty ? overlay.surface.displayName + " 任务" : overlay.title,
                phase: phase,
                actionText: overlay.actionText.isEmpty ? phase.title : overlay.actionText,
                updatedAt: overlay.updatedAt,
                tokenUsage: nil,
                endReason: nil,
                modelName: formattedModel.model.isEmpty ? overlay.model : formattedModel.model,
                reasoningEffort: formattedModel.effort,
                startedAt: overlay.startedAt,
                sessionTotalTokens: nil,
                provider: "Antigravity",
                recentSteps: IslandStep.visibleSteps(from: overlay.steps)
            )
            next.append(row)
        }

        // Settle previously active rows that disappeared abruptly.
        for old in rows where old.phase.isActive && !next.contains(where: { $0.id == old.id }) {
            let turnKey = "\(old.id):\(old.turnID ?? "")"
            var settled = old
            settled.phase = .ended
            settled.endReason = .ended
            settled.updatedAt = now
            settled.suppressCompletion = true
            settled.recentSteps = old.recentSteps.map { $0.endingTask() }
            settledTurns[turnKey] = (.ended, .ended, now)
            receipts[old.id] = settled
            next.append(settled)
        }

        // Keep retained receipts visible in expanded rail until 60s retention elapses, updating isRetainedReceipt.
        for (rowID, var receipt) in receipts where !next.contains(where: { $0.id == rowID }) {
            if now.timeIntervalSince(receipt.updatedAt) < 60 {
                let retainThreshold: TimeInterval = receipt.phase == .completed ? 15 : 6
                receipt.isRetainedReceipt = now.timeIntervalSince(receipt.updatedAt) >= retainThreshold
                receipts[rowID] = receipt
                next.append(receipt)
            } else {
                receipts.removeValue(forKey: rowID)
            }
        }

        if settledTurns.count > 1024 {
            settledTurns = settledTurns.filter { now.timeIntervalSince($0.value.settledAt) < 3600 }
        }

        next.sort { lhs, rhs in
            if lhs.phase.isActive != rhs.phase.isActive { return lhs.phase.isActive }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }

        if rows != next {
            rows = next
            onRowsChanged?()
        }
    }

    private func projectHookOnlyRows(now: Date) {
        projectRows(AntigravityScanResult(
            usage: usage ?? AntigravityUsageSummary(days: [], lifetimeTokens: 0, sessionCount: 0, complete: true, unpricedModels: [], updatedAt: now),
            sessions: []
        ), now: now)
    }

    private func pruneExpiredReceipts(now: Date) {
        receipts = receipts.filter { now.timeIntervalSince($0.value.updatedAt) < 60 }
    }

    // MARK: - Client Activation Fallback

    func surface(for row: ActivitySessionSnapshot) -> AntigravitySurface {
        sessionSurfaces[row.id] ?? .cli
    }

    func fallbackTitle(for row: ActivitySessionSnapshot) -> String {
        switch surface(for: row) {
        case .app: return "在 Antigravity 中处理"
        case .ide: return "在 Antigravity IDE 中处理"
        case .cli: return "回终端处理"
        }
    }

    func openClient(for row: ActivitySessionSnapshot) {
        let targetSurface = surface(for: row)
        let currentInstallation = AntigravityInstallationStatus.detect()
        switch targetSurface {
        case .app:
            if let url = currentInstallation.appURL {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                return
            }
        case .ide:
            if let url = currentInstallation.ideURL {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                return
            }
        case .cli:
            if let iterm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first {
                iterm.activate()
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    private static func detectSurface(from transcriptPath: String) -> AntigravitySurface {
        if transcriptPath.contains("/antigravity-ide/") { return .ide }
        if transcriptPath.contains("/antigravity-cli/") { return .cli }
        if transcriptPath.contains("/antigravity/") { return .app }
        return .cli
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
