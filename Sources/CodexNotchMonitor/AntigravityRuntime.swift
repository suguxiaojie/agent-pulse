import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

@MainActor
final class AntigravityRuntime: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var hooksEnabled: Bool
    @Published private(set) var approvalsEnabled: Bool
    @Published private(set) var statusLineEnabled: Bool
    @Published private(set) var configuring = false
    @Published private(set) var status = "未启用"
    @Published private(set) var error: String?
    @Published private(set) var quota: AntigravityQuotaSnapshot?
    @Published private(set) var usage: AntigravityUsageSummary?
    @Published private(set) var rows: [ActivitySessionSnapshot] = []
    @Published private(set) var requests: [AntigravityPermissionRequest] = []
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
    private var desiredConfiguration: (enabled: Bool, hooks: Bool, approvals: Bool, statusLine: Bool)?
    private var bufferedHooks: [(message: ClaudeCodeBridgeMessage, receivedAt: Date)] = []
    private var requestTimeouts: [String: DispatchWorkItem] = [:]
    private var requestWindow: NSWindow?

    private struct HookOverlay {
        var surface: AntigravitySurface
        var cwd: String = ""
        var title: String = ""
        var model: String?
        var phase: TaskPhase?
        var endReason: SessionEndReason?
        var actionText: String = ""
        var startedAt: Date?
        /// Timestamp when the overlay's current turn began (set only on new turn start, preserved across `Stop`).
        var turnOriginAt: Date?
        var updatedAt = Date.distantPast
        var hookProcessID: pid_t?
        var steps: [IslandStep] = []
        var turnIndex: Int = 0
    }

    private struct SettledTurn {
        var phase: TaskPhase
        var endReason: SessionEndReason
        /// Actual terminal timestamp of the turn (locks elapsed duration display).
        var endedAt: Date
        /// Wall-clock timestamp when Pulse first entered receipt retention (drives 15s/60s expiry).
        var settledAt: Date
        /// True when settled speculatively from SQLite `summaryStatus == .idle` while transcript was still active.
        var speculativeSummaryIdle: Bool = false
    }

    private var hookOverlays: [String: HookOverlay] = [:]
    private var sessionSurfaces: [String: AntigravitySurface] = [:]
    private var observedActiveTurns: Set<String> = []
    private var settledTurns: [String: SettledTurn] = [:]
    private var receipts: [String: ActivitySessionSnapshot] = [:]
    private var lastScan: AntigravityScanResult?
    private var lastStatusLineFileMTime: TimeInterval = 0
    private var lastOneNativeStatusLineMTime: TimeInterval = 0
    private var pendingManualRefresh = false
    private var pendingActivityRefresh = false
    private var summaryGraceRescan: DispatchWorkItem?

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
        self.approvalsEnabled = defaults.object(forKey: "antigravity.approvals") as? Bool ?? true
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
            configure(enabled: true, hooks: hooksEnabled, approvals: approvalsEnabled, statusLine: statusLineEnabled, startup: true)
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
        pendingManualRefresh = false
        pendingActivityRefresh = false
        summaryGraceRescan?.cancel()
        summaryGraceRescan = nil
        configuring = false
        desiredConfiguration = nil
        passthroughAllPendingRequests()
        stopBridge()
        bufferedHooks.removeAll()
        hookOverlays.removeAll()
        sessionSurfaces.removeAll()
        observedActiveTurns.removeAll()
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
                approvals: desiredConfiguration.approvals,
                statusLine: desiredConfiguration.statusLine
            )
        } else {
            configure(enabled: enabled, hooks: hooksEnabled, approvals: approvalsEnabled, statusLine: statusLineEnabled)
        }
    }

    func refresh() {
        refreshInstallation()
        if enabled && statusLineEnabled {
            loadPersistedStatusLineSnapshot(force: true)
        }
        pendingManualRefresh = true
        if enabled && !configuring {
            scanning = true
        }
        refreshActivity(manual: true)
    }

    func configure(enabled target: Bool, hooks: Bool, approvals: Bool? = nil, statusLine: Bool, startup: Bool = false) {
        guard !configuring else { return }
        let resolvedApprovals = approvals ?? self.approvalsEnabled
        desiredConfiguration = (target, hooks, resolvedApprovals, statusLine)
        configuring = true
        error = nil
        status = "配置中"
        generation = UUID()
        let configGeneration = generation
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        pendingManualRefresh = false
        pendingActivityRefresh = false
        summaryGraceRescan?.cancel()
        summaryGraceRescan = nil

        if !target || !hooks || !resolvedApprovals {
            passthroughAllPendingRequests()
        }
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
                    try installer.install(.init(hooks: hooks, interactiveApprovals: resolvedApprovals, statusLine: statusLine))
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
                    self.passthroughAllPendingRequests()
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
                    self.approvalsEnabled = resolvedApprovals
                    self.statusLineEnabled = statusLine
                    self.defaults.set(target, forKey: "antigravity.enabled")
                    self.defaults.set(hooks, forKey: "antigravity.hooks")
                    self.defaults.set(resolvedApprovals, forKey: "antigravity.approvals")
                    self.defaults.set(statusLine, forKey: "antigravity.statusLine")
                    if !target {
                        self.passthroughAllPendingRequests()
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
        if hooksEnabled || statusLineEnabled {
            return "已连接"
        }
        return "仅本地统计"
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
        }, onDisconnect: { [weak self] eventID in
            Task { @MainActor in
                guard let self, self.bridgeGeneration == epoch else { return }
                self.handleDisconnectedRequest(eventID)
            }
        })
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
        var needsActivityRefresh = false
        var deferProjectionForIdle = false
        var seenLiveOneNativeIDs: Set<String> = []
        for item in oneNativeFiles.sorted(by: { $0.mtime > $1.mtime }) {
            guard let data = Self.readPrivateRegularFile(item.url, uid: uid, requirePrivateMode: true, maxBytes: 65_536) else { continue }
            if let rawObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let outcome = ingestOneNativeLiveOverlay(rawObj, now: now, seenLiveConversationIDs: &seenLiveOneNativeIDs)
                if outcome.overlayChanged {
                    overlayChanged = true
                }
                if outcome.needsRefresh {
                    needsActivityRefresh = true
                }
                if outcome.deferStaleProjection {
                    deferProjectionForIdle = true
                } else if outcome.overlayChanged {
                    deferProjectionForIdle = false
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

        if needsActivityRefresh {
            refreshActivity()
        }
        if overlayChanged && !deferProjectionForIdle {
            if let lastScan {
                projectRows(lastScan, now: now)
            } else {
                projectHookOnlyRows(now: now)
            }
        }
    }

    private func ingestOneNativeLiveOverlay(
        _ object: [String: Any],
        now: Date,
        seenLiveConversationIDs: inout Set<String>
    ) -> (overlayChanged: Bool, needsRefresh: Bool, deferStaleProjection: Bool) {
        guard let facts = object["facts"] as? [String: Any],
              let id = (facts["conversation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, id.utf8.count <= 256 else { return (false, false, false) }
        let pidNum = (object["pid"] as? Int) ?? 0
        guard pidNum > 1 else { return (false, false, false) }
        let pid = pid_t(pidNum)
        let alive = Self.isProcessAlive(pid)
        if alive {
            seenLiveConversationIDs.insert(id)
        } else if seenLiveConversationIDs.contains(id) {
            return (false, false, false)
        }
        let observedAt = (object["observed_at"] as? String).flatMap(FastTimestamp.parse)
            ?? Date(timeIntervalSince1970: 0)
        guard observedAt > Date(timeIntervalSince1970: 1_000_000_000),
              observedAt <= now.addingTimeInterval(60) else { return (false, false, false) }

        let agentState = (facts["agent_state"] as? String)?.lowercased() ?? ""
        var overlay = hookOverlays[id] ?? HookOverlay(surface: .cli)
        let beforePhase = overlay.phase
        let beforeModel = overlay.model
        let beforeCwd = overlay.cwd

        if alive || observedAt >= overlay.updatedAt {
            if let cwd = facts["cwd"] as? String, !cwd.isEmpty {
                overlay.cwd = cwd
            }
            if let model = (facts["model_id"] as? String) ?? (facts["model"] as? String), !model.isEmpty {
                overlay.model = model
            }
            if let title = facts["conversation_title"] as? String, !title.isEmpty, overlay.title.isEmpty {
                overlay.title = title
            }
        }

        if agentState == "working", alive, now.timeIntervalSince(observedAt) <= 30 {
            let minAcceptedTimestamp = overlay.endReason != nil
                ? overlay.updatedAt.addingTimeInterval(2.0)
                : overlay.updatedAt
            guard observedAt > minAcceptedTimestamp else {
                let metaChanged = beforeModel != overlay.model || beforeCwd != overlay.cwd
                if metaChanged { hookOverlays[id] = overlay }
                return (metaChanged, false, false)
            }
            overlay.hookProcessID = pid
            overlay.endReason = nil
            var startedNewTurn = false
            if overlay.phase == nil || overlay.phase?.isActive != true {
                overlay.turnIndex += 1
                overlay.turnOriginAt = observedAt
                overlay.startedAt = observedAt
                overlay.steps.removeAll()
                overlay.phase = .working
                startedNewTurn = true
            } else if overlay.turnOriginAt == nil {
                overlay.turnOriginAt = overlay.startedAt ?? observedAt
            }
            overlay.updatedAt = max(overlay.updatedAt, observedAt)
            hookOverlays[id] = overlay
            return (beforePhase != overlay.phase || beforeModel != overlay.model || beforeCwd != overlay.cwd, startedNewTurn, false)
        } else if agentState == "idle" || !alive {
            if !alive, let existingPID = overlay.hookProcessID, existingPID != pid, Self.isProcessAlive(existingPID) {
                return (false, false, false)
            }
            if overlay.phase?.isActive == true, observedAt >= overlay.updatedAt.addingTimeInterval(-1) {
                overlay.phase = nil
                overlay.updatedAt = max(overlay.updatedAt, observedAt)
                hookOverlays[id] = overlay
                let lastScanStillActive = lastScan?.sessions.first(where: { $0.id == id })?.turn.isActive == true
                return (true, true, lastScanStillActive)
            }
            if alive && agentState == "idle" && rows.contains(where: { $0.id == "agy:" + id && $0.phase.isActive }) {
                return (false, true, false)
            }
        }
        return (false, false, false)
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
            if message.awaitsDecision {
                bridge.resolve(eventID: message.eventID, decision: ["decision": "allow"])
            }
            return
        }

        if message.kind == "statusLine" {
            if message.awaitsDecision {
                bridge.resolve(eventID: message.eventID, decision: ["decision": "allow"])
            }
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
                let observedAt: Date = {
                    if let captured = (object["capturedAt"] as? NSNumber)?.doubleValue,
                       captured.isFinite, captured > 1_000_000_000 {
                        let date = Date(timeIntervalSince1970: captured)
                        if date <= receivedAt.addingTimeInterval(5) {
                            return min(date, receivedAt)
                        }
                    }
                    return receivedAt
                }()
                var shouldRefresh = false
                var shouldProject = true
                if let agentState = (object["agent_state"] as? String ?? object["agentState"] as? String)?.lowercased() {
                    if agentState == "working" {
                        let minAccepted = overlay.endReason != nil
                            ? overlay.updatedAt.addingTimeInterval(2.0)
                            : overlay.updatedAt.addingTimeInterval(-1.0)
                        if observedAt > minAccepted {
                            if overlay.phase == nil || overlay.phase?.isActive != true {
                                overlay.turnIndex += 1
                                overlay.turnOriginAt = observedAt
                                overlay.startedAt = observedAt
                                overlay.steps.removeAll()
                                overlay.endReason = nil
                                overlay.phase = .working
                                shouldRefresh = true
                            } else {
                                if overlay.turnOriginAt == nil {
                                    overlay.turnOriginAt = overlay.startedAt ?? observedAt
                                }
                                if overlay.phase != .waitingApproval {
                                    overlay.phase = .working
                                }
                            }
                            overlay.updatedAt = max(overlay.updatedAt, observedAt)
                        }
                    } else if agentState == "idle" {
                        let rowActive = rows.contains { $0.id == "agy:" + sessionID && $0.phase.isActive }
                        if overlay.phase?.isActive == true, observedAt >= overlay.updatedAt.addingTimeInterval(-1.0) {
                            overlay.phase = nil
                            overlay.updatedAt = max(overlay.updatedAt, observedAt)
                            shouldRefresh = true
                            let lastScanStillActive = lastScan?.sessions.first(where: { $0.id == sessionID })?.turn.isActive == true
                            shouldProject = !lastScanStillActive
                        } else if rowActive {
                            shouldRefresh = true
                        }
                    }
                }
                hookOverlays[sessionID] = overlay
                if shouldRefresh {
                    refreshActivity()
                }
                if shouldProject, let lastScan {
                    projectRows(lastScan, now: receivedAt)
                }
            }
            return
        }

        guard configuring ? desiredConfiguration?.hooks == true : hooksEnabled else {
            if message.awaitsDecision {
                bridge.resolve(eventID: message.eventID, decision: ["decision": "allow"])
            }
            return
        }
        if configuring {
            if message.awaitsDecision {
                bridge.resolve(eventID: message.eventID, decision: ["decision": "allow"])
                return
            }
            if bufferedHooks.count >= 256 { bufferedHooks.removeFirst() }
            bufferedHooks.append((message, receivedAt))
            return
        }

        guard let id = object["conversationId"] as? String, !id.isEmpty, id.utf8.count <= 256,
              let event = object["hookEventName"] as? String else {
            if message.awaitsDecision {
                bridge.resolve(eventID: message.eventID, decision: ["decision": "allow"])
            }
            return
        }

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

        if event != "PreToolUse", message.awaitsDecision {
            bridge.resolve(eventID: message.eventID, decision: ["decision": "allow"])
        }

        switch event {
        case "SessionStart":
            hookOverlays[id] = overlay
            return

        case "PreInvocation":
            let invNum = (object["invocationNum"] as? Int) ?? 0
            let isNewTurn = invNum <= 1 || overlay.phase == nil || overlay.endReason != nil
            if isNewTurn {
                overlay.turnIndex += 1
                overlay.turnOriginAt = receivedAt
                overlay.startedAt = receivedAt
                overlay.steps.removeAll()
                overlay.endReason = nil
                overlay.actionText = overlay.title.isEmpty ? "思考中" : overlay.title
            } else if overlay.turnOriginAt == nil {
                overlay.turnOriginAt = overlay.startedAt ?? receivedAt
            }
            overlay.phase = .working
            if overlay.actionText.isEmpty {
                overlay.actionText = overlay.title.isEmpty ? "思考中" : overlay.title
            }
            hookOverlays[id] = overlay
            if isNewTurn {
                refreshActivity()
            }

        case "PreToolUse":
            if overlay.turnIndex == 0 || overlay.endReason != nil {
                overlay.turnIndex += 1
                overlay.turnOriginAt = receivedAt
                overlay.startedAt = receivedAt
                overlay.steps.removeAll()
                overlay.endReason = nil
            } else if overlay.turnOriginAt == nil {
                overlay.turnOriginAt = overlay.startedAt ?? receivedAt
            }
            if let tool = object["toolCall"] as? [String: Any],
               let name = tool["name"] as? String {
                let stepID = (tool["id"] as? String) ?? "hook-\(overlay.steps.count)"
                let summary = (tool["summary"] as? String)
                let title = AntigravityScanner.toolDisplayTitle(
                    name: name,
                    args: (tool["args"] as? [String: Any]) ?? summary.map { ["toolSummary": $0] }
                )
                let stepState: IslandStep.State = message.awaitsDecision ? .waiting : .running
                if let idx = overlay.steps.firstIndex(where: { $0.id == stepID }) {
                    overlay.steps[idx].state = stepState
                } else {
                    overlay.steps.append(.init(id: stepID, title: title, state: stepState))
                    if overlay.steps.count > 32 { overlay.steps.removeFirst(overlay.steps.count - 32) }
                }
            }
            if message.awaitsDecision {
                if approvalsEnabled, let req = AntigravityPermissionRequest.decode(message, receivedAt: receivedAt) {
                    if overlay.turnIndex == 0 {
                        overlay.turnIndex = 1
                        overlay.turnOriginAt = overlay.turnOriginAt ?? receivedAt
                        overlay.startedAt = overlay.startedAt ?? receivedAt
                    }
                    overlay.phase = .waitingApproval
                    overlay.actionText = req.isQuestion
                        ? (req.questions.first?.text ?? "等待回答问题")
                        : "请求使用 \(req.displayToolName)"
                    enqueuePermissionRequest(req)
                } else {
                    bridge.resolve(eventID: message.eventID, decision: ["decision": "allow"])
                    overlay.phase = .usingTool
                }
            } else {
                overlay.phase = .usingTool
            }
            hookOverlays[id] = overlay

        case "PostToolUse":
            if overlay.endReason == nil {
                overlay.phase = .working
            }
            if let tool = object["toolCall"] as? [String: Any],
               let name = tool["name"] as? String {
                if let callID = tool["id"] as? String, !callID.isEmpty {
                    clearRequests(forConversationID: id, matchingToolCallID: callID)
                }
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
            if overlay.endReason == nil {
                overlay.phase = .working
            }
            hookOverlays[id] = overlay
            refreshActivity()

        case "Stop":
            clearRequests(forConversationID: id, matchingToolCallID: nil)
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
            if overlay.turnOriginAt == nil {
                overlay.turnOriginAt = overlay.startedAt
            }
            overlay.phase = terminalPhase
            overlay.endReason = terminalEnd
            hookOverlays[id] = overlay
            let settled = SettledTurn(
                phase: terminalPhase,
                endReason: terminalEnd,
                endedAt: receivedAt,
                settledAt: receivedAt,
                speculativeSummaryIdle: false
            )
            if let existingTurn = rows.first(where: { $0.id == "agy:" + id })?.turnID {
                settledTurns["agy:\(id):\(existingTurn)"] = settled
            }
            if let scanTurn = lastScan?.sessions.first(where: { $0.id == id && $0.turn.isActive })?.turn.turnID {
                settledTurns["agy:\(id):\(scanTurn)"] = settled
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
        let now = Date()
        if pruneExpiredReceipts(now: now), let lastScan {
            projectRows(lastScan, now: now)
        }
        refreshActivity()
    }

    func refreshActivity(manual: Bool = false) {
        guard enabled, !configuring else { return }
        if scanTask != nil {
            pendingActivityRefresh = true
            if manual {
                pendingManualRefresh = true
                scanning = true
            }
            return
        }
        let forceManual = manual || pendingManualRefresh
        pendingManualRefresh = false
        pendingActivityRefresh = false
        if forceManual {
            scanning = true
        }
        let version = generation
        let scanner = scanner
        scanTask = Task(priority: forceManual ? .userInitiated : .utility) { [weak self] in
            let scan = await scanner.scan()
            guard let self, !Task.isCancelled, self.enabled, self.generation == version else { return }
            self.scanTask = nil
            let nextManual = self.pendingManualRefresh
            let nextActivity = self.pendingActivityRefresh
            if !nextManual {
                self.scanning = false
            }
            self.consume(scan, forcePublishUsage: forceManual)
            if nextManual || nextActivity {
                self.pendingManualRefresh = false
                self.pendingActivityRefresh = false
                self.refreshActivity(manual: nextManual)
            }
        }
    }

    private func scheduleSummaryGraceRescan() {
        guard enabled, !configuring, summaryGraceRescan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.summaryGraceRescan = nil
                self.refreshActivity()
            }
        }
        summaryGraceRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
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
            let summaryIdleModifiedAt: Date? = {
                if case .idle(let modifiedAt) = session.summaryStatus { return modifiedAt }
                return nil
            }()
            let turnEffectiveUpdatedAt = max(turn.updatedAt, turn.transcriptModifiedAt ?? .distantPast)
            let turnEffectiveEnd = turn.isActive
                ? turnEffectiveUpdatedAt
                : max(turnEffectiveUpdatedAt, summaryIdleModifiedAt ?? .distantPast)
            let sessionRequests = requests.filter { $0.conversationID == session.id && now < $0.deadline }

            let overlayRecentForNewTurn = overlay.map { ov in
                let maxAge: TimeInterval = (ov.endReason != nil) ? 60 : 30
                return now.timeIntervalSince(ov.updatedAt) <= maxAge
                    && (ov.hookProcessID.map(Self.isProcessAlive) ?? true)
            } ?? false
            let overlayAheadOfTranscript: Bool = {
                guard !turn.isActive else { return false }
                if !sessionRequests.isEmpty { return true }
                guard let ov = overlay, ov.turnIndex > 0, let origin = ov.turnOriginAt else { return false }
                guard overlayRecentForNewTurn else { return false }
                return origin > turnEffectiveEnd.addingTimeInterval(0.5)
            }()

            if overlayAheadOfTranscript {
                let turnID = "hook-\(max(1, overlay?.turnIndex ?? 1))"
                let turnKey = "\(rowID):\(turnID)"
                if let staleReceipt = receipts[rowID], staleReceipt.turnID != turnID {
                    receipts.removeValue(forKey: rowID)
                }
                let sessionTurnPrefix = "\(rowID):"
                for key in Array(observedActiveTurns) where key.hasPrefix(sessionTurnPrefix) && key != turnKey {
                    observedActiveTurns.remove(key)
                }
                let previous = rows.first { $0.id == rowID && $0.turnID == turnID }

                var phase: TaskPhase
                var endReason: SessionEndReason?
                var terminalEndedAt: Date?
                var waitReason: CodexActivityWaitReason?
                var replyIDs: Set<String> = []

                if let latestReq = sessionRequests.last {
                    phase = .waitingApproval
                    endReason = nil
                    waitReason = latestReq.isQuestion ? .userInput : .approval
                    replyIDs = Set(sessionRequests.map(\.id))
                } else if let settled = settledTurns[turnKey] {
                    phase = settled.phase
                    endReason = settled.endReason
                    terminalEndedAt = settled.endedAt
                } else if let ov = overlay, let ovPhase = ov.phase {
                    if ovPhase.isActive {
                        if live {
                            phase = ovPhase
                            endReason = nil
                        } else {
                            phase = .ended
                            endReason = .ended
                            terminalEndedAt = now
                        }
                    } else {
                        phase = ovPhase
                        endReason = ov.endReason ?? .ended
                        terminalEndedAt = ov.updatedAt > .distantPast ? min(now, ov.updatedAt) : now
                    }
                } else {
                    continue
                }

                let wasObservedActive = observedActiveTurns.contains(turnKey) || !sessionRequests.isEmpty
                let existingReceipt = receipts[rowID]
                guard (live && phase.isActive) || !sessionRequests.isEmpty || previous?.phase.isActive == true || existingReceipt != nil || (wasObservedActive && endReason != nil) else {
                    continue
                }

                let cwd = (overlay?.cwd.isEmpty == false ? overlay!.cwd : nil) ?? session.cwd
                let projectName = cwd.isEmpty ? session.surface.shortName : URL(fileURLWithPath: cwd).lastPathComponent
                let rawModel = overlay?.model ?? session.model
                let formattedModel = AntigravityPricing.formatModel(rawModel)
                let overlaySteps = (overlay?.steps ?? []).map { endReason != nil ? $0.endingTask() : $0 }
                let mergedSteps = IslandStep.visibleSteps(from: overlaySteps)
                let actionText: String
                if let latestReq = sessionRequests.last {
                    actionText = latestReq.isQuestion
                        ? (latestReq.questions.first?.text ?? "请在灵动岛回答问题")
                        : "请求使用 \(latestReq.displayToolName)"
                } else if endReason == .cancelled {
                    actionText = "已取消"
                } else if let ovText = overlay?.actionText, !ovText.isEmpty {
                    actionText = ovText
                } else {
                    actionText = phase.title
                }

                var settledEntry: SettledTurn?
                if let endReason {
                    if let existingSettled = settledTurns[turnKey] {
                        settledEntry = existingSettled
                    } else {
                        let resolvedEnded = terminalEndedAt ?? now
                        let created = SettledTurn(
                            phase: phase,
                            endReason: endReason,
                            endedAt: resolvedEnded,
                            settledAt: now,
                            speculativeSummaryIdle: false
                        )
                        settledTurns[turnKey] = created
                        settledEntry = created
                    }
                }

                let resolvedStartedAt = overlay?.startedAt ?? overlay?.turnOriginAt
                let updatedAt: Date
                if endReason == nil {
                    updatedAt = max(overlay?.updatedAt ?? .distantPast, sessionRequests.last?.receivedAt ?? .distantPast)
                } else if let settledEntry {
                    if let startedAt = resolvedStartedAt, settledEntry.endedAt < startedAt {
                        updatedAt = startedAt
                    } else {
                        updatedAt = settledEntry.endedAt
                    }
                } else {
                    updatedAt = now
                }

                let resolvedTitle = (overlay?.title.isEmpty == false ? overlay!.title : nil) ?? session.title
                var row = ActivitySessionSnapshot(
                    sessionID: rowID,
                    turnID: turnID,
                    projectID: "agy:" + (cwd.isEmpty ? session.surface.rawValue : cwd),
                    projectName: projectName,
                    title: resolvedTitle,
                    phase: phase,
                    actionText: actionText,
                    updatedAt: updatedAt == .distantPast ? now : updatedAt,
                    tokenUsage: nil,
                    endReason: endReason,
                    modelName: formattedModel.model.isEmpty ? rawModel : formattedModel.model,
                    reasoningEffort: formattedModel.effort,
                    startedAt: resolvedStartedAt,
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
                } else if wasObservedActive || existingReceipt != nil || previous?.phase.isActive == true {
                    let settledAt = settledEntry?.settledAt ?? now
                    let receiptAge = now.timeIntervalSince(settledAt)
                    let retainThreshold: TimeInterval = row.phase == .completed ? 15 : 6
                    row.isRetainedReceipt = receiptAge >= retainThreshold
                    if receiptAge < 60 {
                        receipts[rowID] = row
                        next.append(row)
                    } else {
                        receipts.removeValue(forKey: rowID)
                        observedActiveTurns.remove(turnKey)
                    }
                }
                continue
            }

            let resolvedTurnID = turn.turnID ?? overlay.map { "hook-\(max(1, $0.turnIndex))" }
            guard let turnID = resolvedTurnID else { continue }
            let turnKey = "\(rowID):\(turnID)"
            if let staleReceipt = receipts[rowID], staleReceipt.turnID != turnID {
                if let staleTurn = staleReceipt.turnID,
                   staleTurn.hasPrefix("hook-"),
                   turnID.hasPrefix("step-"),
                   (staleReceipt.startedAt.flatMap { hs in turn.startedAt.map { abs($0.timeIntervalSince(hs)) <= 10 } } ?? false) {
                    let staleKey = "\(rowID):\(staleTurn)"
                    if settledTurns[turnKey] == nil, let carried = settledTurns[staleKey] {
                        settledTurns[turnKey] = carried
                    }
                    observedActiveTurns.insert(turnKey)
                }
                receipts.removeValue(forKey: rowID)
            }
            if let activeHookRow = rows.first(where: { $0.id == rowID && $0.phase.isActive && ($0.turnID?.hasPrefix("hook-") == true) }) {
                let matchesHookTurn = turn.isActive || (activeHookRow.startedAt.flatMap { hs in
                    turn.startedAt.map { $0 >= hs.addingTimeInterval(-10) }
                } ?? false)
                if matchesHookTurn {
                    observedActiveTurns.insert(turnKey)
                }
            }
            let sessionTurnPrefix = "\(rowID):"
            for key in Array(observedActiveTurns) where key.hasPrefix(sessionTurnPrefix) && key != turnKey {
                observedActiveTurns.remove(key)
            }
            let previous = rows.first { row in
                guard row.id == rowID else { return false }
                if row.turnID == turnID { return true }
                guard row.phase.isActive,
                      row.turnID?.hasPrefix("hook-") == true,
                      turnID.hasPrefix("step-") else { return false }
                return turn.isActive || (row.startedAt.flatMap { hs in
                    turn.startedAt.map { abs($0.timeIntervalSince(hs)) <= 10 }
                } ?? false)
            }

            var phase: TaskPhase
            var endReason: SessionEndReason?
            var terminalEndedAt: Date?
            var waitReason: CodexActivityWaitReason?
            var replyIDs: Set<String> = []

            let summaryStopped: (reason: SessionEndReason, endedAt: Date, speculative: Bool)? = {
                switch session.summaryStatus {
                case .killed:
                    return (.ended, now, false)
                case .canceling:
                    return (.cancelled, now, false)
                case .idle(let modifiedAt):
                    if let modifiedAt, modifiedAt >= turnEffectiveUpdatedAt.addingTimeInterval(-0.5) {
                        if turn.phase == .working && now.timeIntervalSince(modifiedAt) < 0.8 {
                            scheduleSummaryGraceRescan()
                            return nil
                        }
                        return (.cancelled, min(now, modifiedAt), true)
                    }
                    if now.timeIntervalSince(turnEffectiveUpdatedAt) >= 2.0 {
                        return (.cancelled, min(now, modifiedAt ?? now), true)
                    }
                    return nil
                case .running, .unknown:
                    return nil
                }
            }()

            if let existingSettled = settledTurns[turnKey] {
                let baseline = max(existingSettled.endedAt, existingSettled.settledAt)
                let resumedByTranscript = (turn.isActive || session.summaryStatus == .running)
                    && turnEffectiveUpdatedAt > baseline.addingTimeInterval(0.5)
                let resumedByOverlay = live && hookAlive
                    && overlay?.phase?.isActive == true
                    && (overlay?.updatedAt ?? .distantPast) > baseline.addingTimeInterval(0.5)
                    && (turn.isActive || session.summaryStatus == .running)
                if resumedByTranscript || resumedByOverlay {
                    settledTurns.removeValue(forKey: turnKey)
                } else if existingSettled.speculativeSummaryIdle, !turn.isActive, turn.phase == .completed {
                    settledTurns[turnKey] = SettledTurn(
                        phase: .completed,
                        endReason: .completed,
                        endedAt: turnEffectiveUpdatedAt > .distantPast ? min(now, turnEffectiveUpdatedAt) : now,
                        settledAt: existingSettled.settledAt,
                        speculativeSummaryIdle: false
                    )
                }
            }

            let activeOverlayNewerThanTurn = live && hookAlive
                && overlay?.phase?.isActive == true
                && (overlay?.updatedAt ?? .distantPast) > turnEffectiveUpdatedAt.addingTimeInterval(0.5)

            if let settled = settledTurns[turnKey] {
                phase = settled.phase
                endReason = settled.endReason
                terminalEndedAt = settled.endedAt
            } else if turn.isActive, let stop = summaryStopped, !activeOverlayNewerThanTurn {
                phase = .ended
                endReason = stop.reason
                terminalEndedAt = stop.endedAt
                settledTurns[turnKey] = SettledTurn(
                    phase: phase,
                    endReason: stop.reason,
                    endedAt: stop.endedAt,
                    settledAt: now,
                    speculativeSummaryIdle: stop.speculative
                )
            } else if let ov = overlay, let ovPhase = ov.phase,
                      ov.updatedAt > turnEffectiveUpdatedAt,
                      (turn.isActive || !ovPhase.isActive),
                      (!ovPhase.isActive || hookAlive) {
                if ovPhase.isActive && !live {
                    phase = .ended
                    endReason = .ended
                    terminalEndedAt = now
                    settledTurns[turnKey] = SettledTurn(
                        phase: .ended,
                        endReason: .ended,
                        endedAt: now,
                        settledAt: now
                    )
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
                        let endedAt = ov.updatedAt > .distantPast ? min(now, ov.updatedAt) : now
                        terminalEndedAt = endedAt
                        settledTurns[turnKey] = SettledTurn(
                            phase: ovPhase,
                            endReason: er,
                            endedAt: endedAt,
                            settledAt: now
                        )
                    }
                }
            } else {
                if !turn.isActive, var staleOverlay = hookOverlays[session.id], staleOverlay.phase?.isActive == true {
                    staleOverlay.phase = nil
                    hookOverlays[session.id] = staleOverlay
                }
                switch turn.phase {
                case .working:
                    phase = live ? .working : .ended
                    endReason = live ? nil : .ended
                    if !live { terminalEndedAt = now }
                case .tool:
                    phase = live ? .usingTool : .ended
                    endReason = live ? nil : .ended
                    if !live { terminalEndedAt = now }
                case .waitingQuestion:
                    phase = live ? .waitingApproval : .ended
                    endReason = live ? nil : .ended
                    if live {
                        waitReason = .userInput
                        replyIDs = ["\(turnKey):question"]
                    } else {
                        terminalEndedAt = now
                    }
                case .completed:
                    phase = .completed
                    endReason = .completed
                    terminalEndedAt = turnEffectiveUpdatedAt > .distantPast ? min(now, turnEffectiveUpdatedAt) : now
                case .failed:
                    phase = .failed
                    endReason = .failed
                    terminalEndedAt = turnEffectiveUpdatedAt > .distantPast ? min(now, turnEffectiveUpdatedAt) : now
                case .cancelled:
                    phase = .ended
                    endReason = .cancelled
                    terminalEndedAt = turnEffectiveUpdatedAt > .distantPast ? min(now, turnEffectiveUpdatedAt) : now
                case .idle:
                    continue
                }
            }

            if let latestReq = sessionRequests.last {
                phase = .waitingApproval
                endReason = nil
                waitReason = latestReq.isQuestion ? .userInput : .approval
                replyIDs = Set(sessionRequests.map(\.id))
            }

            let wasObservedActive = observedActiveTurns.contains(turnKey) || !sessionRequests.isEmpty
            let existingReceipt = receipts[rowID]
            guard (live && phase.isActive) || !sessionRequests.isEmpty || previous?.phase.isActive == true || existingReceipt != nil || (wasObservedActive && endReason != nil) else {
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
            if let latestReq = sessionRequests.last {
                actionText = latestReq.isQuestion
                    ? (latestReq.questions.first?.text ?? "请在灵动岛回答问题")
                    : "请求使用 \(latestReq.displayToolName)"
            } else if phase == .waitingApproval {
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

            var settledEntry: SettledTurn?
            if let endReason {
                if let existingSettled = settledTurns[turnKey] {
                    settledEntry = existingSettled
                } else {
                    let fallbackEnded = turnEffectiveUpdatedAt > .distantPast ? min(now, turnEffectiveUpdatedAt) : now
                    let resolvedEnded = terminalEndedAt ?? fallbackEnded
                    let created = SettledTurn(
                        phase: phase,
                        endReason: endReason,
                        endedAt: resolvedEnded,
                        settledAt: now
                    )
                    settledTurns[turnKey] = created
                    settledEntry = created
                }
            }

            let resolvedStartedAt = turn.startedAt ?? overlay?.startedAt
            let updatedAt: Date
            if endReason == nil {
                updatedAt = max(turnEffectiveUpdatedAt, overlay?.updatedAt ?? .distantPast)
            } else if let settledEntry {
                if let startedAt = resolvedStartedAt, settledEntry.endedAt < startedAt {
                    updatedAt = startedAt
                } else {
                    updatedAt = settledEntry.endedAt
                }
            } else {
                updatedAt = now
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
                startedAt: resolvedStartedAt,
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
            } else if wasObservedActive || existingReceipt != nil || previous?.phase.isActive == true {
                let settledAt = settledEntry?.settledAt ?? now
                let receiptAge = now.timeIntervalSince(settledAt)
                let retainThreshold: TimeInterval = row.phase == .completed ? 15 : 6
                row.isRetainedReceipt = receiptAge >= retainThreshold
                if receiptAge < 60 {
                    receipts[rowID] = row
                    next.append(row)
                } else {
                    receipts.removeValue(forKey: rowID)
                    observedActiveTurns.remove(turnKey)
                }
            }
        }

        // Handle hook-only sessions whose transcript file has not flushed its first step yet.
        for (id, overlay) in hookOverlays where !handledIDs.contains(id) {
            let sessionRequests = requests.filter { $0.conversationID == id && now < $0.deadline }
            let latestReq = sessionRequests.last
            let resolvedPhase = latestReq != nil ? .waitingApproval : overlay.phase
            guard let phase = resolvedPhase else { continue }
            let rowID = "agy:" + id
            let turnID = "hook-\(max(1, overlay.turnIndex))"
            let turnKey = "\(rowID):\(turnID)"
            let formattedModel = AntigravityPricing.formatModel(overlay.model)
            let projectName = overlay.cwd.isEmpty ? overlay.surface.shortName : URL(fileURLWithPath: overlay.cwd).lastPathComponent

            if phase.isActive {
                let maxIdleAge: TimeInterval = latestReq != nil ? 130 : 30
                guard now.timeIntervalSince(overlay.updatedAt) <= maxIdleAge,
                      overlay.hookProcessID.map(Self.isProcessAlive) ?? true else { continue }
                sessionSurfaces[rowID] = overlay.surface
                observedActiveTurns.insert(turnKey)
                receipts.removeValue(forKey: rowID)
                let resolvedActionText: String = {
                    if let latestReq {
                        return latestReq.isQuestion
                            ? (latestReq.questions.first?.text ?? "请在灵动岛回答问题")
                            : "请求使用 \(latestReq.displayToolName)"
                    }
                    return overlay.actionText.isEmpty ? phase.title : overlay.actionText
                }()
                let row = ActivitySessionSnapshot(
                    sessionID: rowID,
                    turnID: turnID,
                    projectID: "agy:" + (overlay.cwd.isEmpty ? overlay.surface.rawValue : overlay.cwd),
                    projectName: projectName,
                    title: overlay.title.isEmpty ? overlay.surface.displayName + " 任务" : overlay.title,
                    phase: phase,
                    actionText: resolvedActionText,
                    updatedAt: max(overlay.updatedAt, latestReq?.receivedAt ?? .distantPast),
                    tokenUsage: nil,
                    endReason: nil,
                    modelName: formattedModel.model.isEmpty ? overlay.model : formattedModel.model,
                    reasoningEffort: formattedModel.effort,
                    startedAt: overlay.startedAt,
                    sessionTotalTokens: nil,
                    provider: "Antigravity",
                    waitReason: latestReq.map { $0.isQuestion ? .userInput : .approval },
                    replyRequestIDs: Set(sessionRequests.map(\.id)),
                    recentSteps: IslandStep.visibleSteps(from: overlay.steps)
                )
                next.append(row)
            } else if let endReason = overlay.endReason {
                let previous = rows.first { $0.id == rowID && $0.turnID == turnID }
                let wasObservedActive = observedActiveTurns.contains(turnKey) || previous?.phase.isActive == true
                let existingReceipt = receipts[rowID]
                guard wasObservedActive || existingReceipt != nil else { continue }
                sessionSurfaces[rowID] = overlay.surface
                let settled: SettledTurn
                if let existingSettled = settledTurns[turnKey] {
                    settled = existingSettled
                } else {
                    let endedAt = overlay.updatedAt > .distantPast ? min(now, overlay.updatedAt) : now
                    let created = SettledTurn(
                        phase: phase,
                        endReason: endReason,
                        endedAt: endedAt,
                        settledAt: now,
                        speculativeSummaryIdle: false
                    )
                    settledTurns[turnKey] = created
                    settled = created
                }
                let receiptAge = now.timeIntervalSince(settled.settledAt)
                guard receiptAge < 60 else {
                    receipts.removeValue(forKey: rowID)
                    observedActiveTurns.remove(turnKey)
                    continue
                }
                let retainThreshold: TimeInterval = settled.phase == .completed ? 15 : 6
                let resolvedActionText = endReason == .cancelled
                    ? "已取消"
                    : (overlay.actionText.isEmpty ? settled.phase.title : overlay.actionText)
                let endedAt: Date = {
                    if let startedAt = overlay.startedAt, settled.endedAt < startedAt { return startedAt }
                    return settled.endedAt
                }()
                var row = ActivitySessionSnapshot(
                    sessionID: rowID,
                    turnID: turnID,
                    projectID: "agy:" + (overlay.cwd.isEmpty ? overlay.surface.rawValue : overlay.cwd),
                    projectName: projectName,
                    title: overlay.title.isEmpty ? overlay.surface.displayName + " 任务" : overlay.title,
                    phase: settled.phase,
                    actionText: resolvedActionText,
                    updatedAt: endedAt,
                    tokenUsage: nil,
                    endReason: settled.endReason,
                    modelName: formattedModel.model.isEmpty ? overlay.model : formattedModel.model,
                    reasoningEffort: formattedModel.effort,
                    startedAt: overlay.startedAt,
                    sessionTotalTokens: nil,
                    provider: "Antigravity",
                    waitReason: nil,
                    replyRequestIDs: [],
                    suppressCompletion: !wasObservedActive,
                    recentSteps: IslandStep.visibleSteps(from: overlay.steps.map { $0.endingTask() })
                )
                row.isRetainedReceipt = receiptAge >= retainThreshold
                receipts[rowID] = row
                next.append(row)
            }
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
            settledTurns[turnKey] = SettledTurn(
                phase: .ended,
                endReason: .ended,
                endedAt: now,
                settledAt: now
            )
            receipts[old.id] = settled
            next.append(settled)
        }

        // Keep retained receipts visible in expanded rail until 60s retention elapses, updating isRetainedReceipt.
        for (rowID, var receipt) in receipts where !next.contains(where: { $0.id == rowID }) {
            let turnKey = "\(receipt.id):\(receipt.turnID ?? "")"
            let settledAt = settledTurns[turnKey]?.settledAt ?? receipt.updatedAt
            let receiptAge = now.timeIntervalSince(settledAt)
            if receiptAge < 60 {
                let retainThreshold: TimeInterval = receipt.phase == .completed ? 15 : 6
                receipt.isRetainedReceipt = receiptAge >= retainThreshold
                receipts[rowID] = receipt
                next.append(receipt)
            } else {
                receipts.removeValue(forKey: rowID)
                observedActiveTurns.remove(turnKey)
            }
        }

        if settledTurns.count > 1024 {
            settledTurns = settledTurns.filter { now.timeIntervalSince($0.value.settledAt) < 3600 }
        }
        if observedActiveTurns.count > 1024 {
            observedActiveTurns = Set(next.map { "\($0.id):\($0.turnID ?? "")" })
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

    @discardableResult
    private func pruneExpiredReceipts(now: Date) -> Bool {
        var pruned = false
        for (rowID, receipt) in receipts {
            let turnKey = "\(receipt.id):\(receipt.turnID ?? "")"
            let settledAt = settledTurns[turnKey]?.settledAt ?? receipt.updatedAt
            if now.timeIntervalSince(settledAt) >= 60 {
                receipts.removeValue(forKey: rowID)
                observedActiveTurns.remove(turnKey)
                pruned = true
            }
        }
        let expiredIDs = requests.filter { now >= $0.deadline }.map(\.id)
        for id in expiredIDs {
            expireRequest(id)
        }
        return pruned
    }

    // MARK: - Interactive Approvals & Questions

    private func enqueuePermissionRequest(_ request: AntigravityPermissionRequest) {
        requestTimeouts.removeValue(forKey: request.id)?.cancel()
        requests.removeAll { $0.id == request.id }
        requests.append(request)

        let reqID = request.id
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.expireRequest(reqID)
            }
        }
        requestTimeouts[reqID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AntigravityPermissionRequest.decisionTimeoutSeconds, execute: item)
    }

    private func expireRequest(_ id: String) {
        guard let req = requests.first(where: { $0.id == id }) else { return }
        requestTimeouts.removeValue(forKey: id)?.cancel()
        requests.removeAll { $0.id == id }
        bridge.resolve(eventID: id, decision: ["decision": "allow"])
        if var overlay = hookOverlays[req.conversationID], overlay.phase == .waitingApproval {
            overlay.phase = .working
            overlay.updatedAt = Date()
            hookOverlays[req.conversationID] = overlay
        }
        reprojectCurrentRows()
    }

    private func handleDisconnectedRequest(_ id: String) {
        guard let req = requests.first(where: { $0.id == id }) else { return }
        requestTimeouts.removeValue(forKey: id)?.cancel()
        requests.removeAll { $0.id == id }
        if var overlay = hookOverlays[req.conversationID], overlay.phase == .waitingApproval {
            overlay.phase = .working
            overlay.updatedAt = Date()
            hookOverlays[req.conversationID] = overlay
        }
        reprojectCurrentRows()
    }

    private func clearRequests(forConversationID conversationID: String, matchingToolCallID toolCallID: String?) {
        let matching = requests.filter { req in
            guard req.conversationID == conversationID else { return false }
            if let toolCallID { return req.toolCallID == toolCallID }
            return true
        }
        for req in matching {
            requestTimeouts.removeValue(forKey: req.id)?.cancel()
            requests.removeAll { $0.id == req.id }
            bridge.resolve(eventID: req.id, decision: ["decision": "allow"])
        }
    }

    private func passthroughAllPendingRequests() {
        for item in requestTimeouts.values { item.cancel() }
        requestTimeouts.removeAll()
        let pending = requests
        requests.removeAll()
        for req in pending {
            bridge.resolve(eventID: req.id, decision: ["decision": "allow"])
        }
    }

    private func reprojectCurrentRows() {
        let now = Date()
        if let lastScan {
            projectRows(lastScan, now: now)
        } else {
            projectHookOnlyRows(now: now)
        }
    }

    @discardableResult
    func respond(_ id: String, choice: AntigravityPermissionRequest.Choice, answers: [String: String] = [:]) -> Bool {
        guard enabled, hooksEnabled, approvalsEnabled, !configuring,
              let req = requests.first(where: { $0.id == id }) else {
            return false
        }
        guard Date() < req.deadline else {
            returnToClient(id)
            return false
        }
        guard let decision = req.decision(choice, answers: answers) else {
            return false
        }
        requestTimeouts.removeValue(forKey: id)?.cancel()
        requests.removeAll { $0.id == id }
        bridge.resolve(eventID: id, decision: decision)
        if var overlay = hookOverlays[req.conversationID] {
            overlay.phase = .working
            overlay.actionText = req.isQuestion ? "已提交回答，等待继续执行" : "已发送审批决定"
            overlay.updatedAt = Date()
            hookOverlays[req.conversationID] = overlay
        }
        reprojectCurrentRows()
        return true
    }

    func returnToClient(_ id: String) {
        guard let req = requests.first(where: { $0.id == id }) else { return }
        requestTimeouts.removeValue(forKey: id)?.cancel()
        requests.removeAll { $0.id == id }
        bridge.resolve(eventID: id, decision: ["decision": "allow"])
        if var overlay = hookOverlays[req.conversationID] {
            overlay.phase = .working
            overlay.actionText = "已交回 \(req.surface.displayName)"
            overlay.updatedAt = Date()
            hookOverlays[req.conversationID] = overlay
        }
        reprojectCurrentRows()
        openSurface(req.surface)
    }

    func showRequests() {
        if requestWindow == nil {
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Antigravity 请求"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AntigravityRequestsView(runtime: self))
            requestWindow = window
        }
        requestWindow?.center()
        requestWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Client Activation Fallback

    func surface(for row: ActivitySessionSnapshot) -> AntigravitySurface {
        sessionSurfaces[row.id] ?? .cli
    }

    func fallbackTitle(for row: ActivitySessionSnapshot) -> String {
        fallbackTitle(for: surface(for: row))
    }

    func fallbackTitle(for surface: AntigravitySurface) -> String {
        switch surface {
        case .app: return "在 Antigravity 中处理"
        case .ide: return "在 Antigravity IDE 中处理"
        case .cli: return "回终端处理"
        }
    }

    func openClient(for row: ActivitySessionSnapshot) {
        openSurface(surface(for: row))
    }

    func openSurface(_ targetSurface: AntigravitySurface) {
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
