import AppKit
import SwiftUI

@main
@MainActor
enum AntigravityRuntimeTests {
    static func main() async throws {
        let helperPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        precondition(!helperPath.isEmpty && FileManager.default.isExecutableFile(atPath: helperPath), "helper binary required")

        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), "FAIL: \(message)")
            checks += 1
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ag-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let suiteName = "com.coverai.codex-pulse.test.ag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let geminiDir = tempRoot.appendingPathComponent(".gemini", isDirectory: true)
        let supportDir = tempRoot.appendingPathComponent("support", isDirectory: true)
        let socketURL = URL(fileURLWithPath: "/tmp/ag-rt-\(UUID().uuidString.prefix(8)).sock")
        defer { unlink(socketURL.path); unlink(socketURL.path + ".lock") }

        let installer = AntigravityInstaller(
            socketURL: socketURL,
            authenticationToken: "rt-token-999",
            geminiDirectory: geminiDir,
            supportDirectory: supportDir,
            helperURL: URL(fileURLWithPath: helperPath)
        )
        let scanner = AntigravityScanner(geminiDirectory: geminiDir)
        let runtime = AntigravityRuntime(
            defaults: defaults,
            installer: installer,
            scanner: scanner,
            installation: AntigravityInstallationStatus(
                appURL: URL(fileURLWithPath: "/Applications/Antigravity.app"),
                ideURL: URL(fileURLWithPath: "/Applications/Antigravity IDE.app"),
                cliURL: URL(fileURLWithPath: "/Users/dev/.local/bin/agy")
            ),
            configurationQueue: .main
        )
        runtime.start()
        defer { runtime.stop() }

        expect(!runtime.enabled && runtime.rows.isEmpty, "disabled by default")

        runtime.configure(enabled: true, hooks: true, statusLine: true)
        for _ in 0..<40 where runtime.configuring {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        expect(runtime.enabled && installer.state().hooksInstalled && installer.state().statusLineInstalled, "runtime enabled and installed")

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        // 1. Historical completed session on initial scan must NOT appear as fresh completion celebration!
        let historicalScan = AntigravityScanResult(
            usage: AntigravityUsageSummary(
                days: [
                    .init(date: Calendar.current.startOfDay(for: now), tokens: 12_000, inputTokens: 4_000, cacheReadTokens: 7_000, outputTokens: 1_000, knownCost: 0, hasUnpriced: true)
                ],
                lifetimeTokens: 12_000,
                sessionCount: 1,
                complete: true,
                unpricedModels: ["gemini-4-carbon-medium"],
                updatedAt: now
            ),
            sessions: [
                AntigravitySessionRecord(
                    id: "hist-1",
                    surface: .app,
                    cwd: "/Users/dev/HistoryRepo",
                    title: "Old Completed Task",
                    model: "gemini-4-carbon-medium",
                    totalTokens: 12_000,
                    isSubagent: false,
                    isLockedLive: false,
                    summaryBusy: false,
                    caughtUp: true,
                    turn: .init(turnID: "step-0", phase: .completed, startedAt: now.addingTimeInterval(-300), updatedAt: now.addingTimeInterval(-200), tokens: 12_000, text: "Done long ago", steps: [])
                )
            ]
        )
        runtime.consume(historicalScan, now: now)
        expect(runtime.rows.isEmpty, "historical completed session does not create an island card")

        // 2. Live session progresses: working -> waitingQuestion -> completed (eligible for celebration!)
        let workingScan = AntigravityScanResult(
            usage: historicalScan.usage,
            sessions: [
                AntigravitySessionRecord(
                    id: "live-1",
                    surface: .app,
                    cwd: "/Users/dev/PulseProject",
                    title: "Adapt Antigravity",
                    model: "gemini-4-carbon-medium",
                    totalTokens: 5_000,
                    isSubagent: false,
                    isLockedLive: true,
                    summaryBusy: true,
                    caughtUp: true,
                    turn: .init(
                        turnID: "step-4",
                        phase: .waitingQuestion,
                        startedAt: now,
                        updatedAt: now.addingTimeInterval(5),
                        tokens: 5_000,
                        text: "请在 Antigravity 中回答问题",
                        steps: [.init(id: "s5-0", title: "等待用户回答", status: "waiting")]
                    )
                )
            ]
        )
        runtime.consume(workingScan, now: now.addingTimeInterval(5))
        expect(runtime.rows.count == 1, "live session creates island row")
        let waitingRow = runtime.rows[0]
        expect(waitingRow.phase == .waitingApproval && waitingRow.waitReason == .userInput, "ask_question maps to waitingApproval userInput")
        expect(waitingRow.modelName == "Gemini 4 Carbon" && waitingRow.reasoningEffort == "Medium", "model formatted on row")
        expect(runtime.fallbackTitle(for: waitingRow) == "在 Antigravity 中处理", "surface-specific fallback button title")

        let completedScan = AntigravityScanResult(
            usage: historicalScan.usage,
            sessions: [
                AntigravitySessionRecord(
                    id: "live-1",
                    surface: .app,
                    cwd: "/Users/dev/PulseProject",
                    title: "Adapt Antigravity",
                    model: "gemini-4-carbon-medium",
                    totalTokens: 9_000,
                    isSubagent: false,
                    isLockedLive: true,
                    summaryBusy: false,
                    caughtUp: true,
                    turn: .init(
                        turnID: "step-4",
                        phase: .completed,
                        startedAt: now,
                        updatedAt: now.addingTimeInterval(20),
                        tokens: 9_000,
                        text: "Antigravity 适配完成",
                        steps: [.init(id: "s5-0", title: "等待用户回答", status: "completed")]
                    )
                )
            ]
        )
        let prevRows = runtime.rows
        runtime.consume(completedScan, now: now.addingTimeInterval(20))
        expect(ActivitySessionSnapshot.newlyCompleted(in: runtime.rows, previous: prevRows) != nil,
               "observed live turn transitioning to completed triggers celebration")

        // 2b. Pressing Esc mid-tool in an open terminal: transcript stays at .tool, lock stays true,
        // but SQLite summary transitions to CASCADE_RUN_STATUS_IDLE -> must immediately end as cancelled and return compact island to idle banner!
        let escStartScan = AntigravityScanResult(
            usage: historicalScan.usage,
            sessions: [
                AntigravitySessionRecord(
                    id: "live-esc",
                    surface: .cli,
                    cwd: "/Users/dev/PulseProject",
                    title: "Test Esc",
                    model: "gemini-4-carbon-medium",
                    totalTokens: 2_000,
                    isSubagent: false,
                    isLockedLive: true,
                    summaryBusy: true,
                    summaryStatus: .running,
                    caughtUp: true,
                    turn: .init(
                        turnID: "step-282",
                        phase: .tool,
                        startedAt: now.addingTimeInterval(30),
                        updatedAt: now.addingTimeInterval(32),
                        tokens: 2_000,
                        text: "执行命令",
                        steps: [.init(id: "s287-0", title: "执行命令", status: "running")]
                    )
                )
            ]
        )
        runtime.consume(escStartScan, now: now.addingTimeInterval(32))
        expect(runtime.rows.first(where: { $0.id == "agy:live-esc" })?.phase == .usingTool, "CLI tool turn starts active")

        let escCanceledScan = AntigravityScanResult(
            usage: historicalScan.usage,
            sessions: [
                AntigravitySessionRecord(
                    id: "live-esc",
                    surface: .cli,
                    cwd: "/Users/dev/PulseProject",
                    title: "Test Esc",
                    model: "gemini-4-carbon-medium",
                    totalTokens: 2_000,
                    isSubagent: false,
                    isLockedLive: true,
                    summaryBusy: false,
                    summaryStatus: .idle(modifiedAt: now.addingTimeInterval(34)),
                    caughtUp: true,
                    turn: escStartScan.sessions[0].turn // transcript.jsonl unchanged on Esc!
                )
            ]
        )
        let beforeEsc = runtime.rows
        runtime.consume(escCanceledScan, now: now.addingTimeInterval(34))
        let escRow = runtime.rows.first { $0.id == "agy:live-esc" }
        expect(escRow?.phase == .ended && escRow?.endReason == .cancelled && escRow?.statusTitle == "已取消",
               "Esc mid-tool immediately transitions row to cancelled")
        expect(ActivitySessionSnapshot.newlyCompleted(in: runtime.rows, previous: beforeEsc) == nil,
               "Esc cancellation never triggers completion celebration")
        expect(escRow?.recentSteps.allSatisfy { !$0.state.isActive } == true, "active steps settled on Esc")

        // After 6 seconds, receipt becomes retained so compact island returns to idle quota banner, and never revives as active!
        runtime.consume(escCanceledScan, now: now.addingTimeInterval(41))
        let retainedEscRow = runtime.rows.first { $0.id == "agy:live-esc" }
        expect(retainedEscRow?.isRetainedReceipt == true && retainedEscRow?.phase == .ended, "canceled row transitions to retained receipt without reviving")
        let compactCheckModel = ActivityIslandViewModel()
        compactCheckModel.sessions = [retainedEscRow!]
        expect(compactCheckModel.showsCompactQuota, "compact island returns to idle quota banner once cancel receipt settles")

        // 2c. Reactive wakeup within the same USER_INPUT turnID (e.g. background task finishes after >60s):
        // previously settled turnKey must clear and re-surface as active in Dynamic Island!
        let resumedTurnScan = AntigravityScanResult(
            usage: historicalScan.usage,
            sessions: [
                AntigravitySessionRecord(
                    id: "live-esc",
                    surface: .cli,
                    cwd: "/Users/dev/PulseProject",
                    title: "Test Esc",
                    model: "gemini-4-carbon-medium",
                    totalTokens: 8_500,
                    isSubagent: false,
                    isLockedLive: true,
                    summaryBusy: true,
                    summaryStatus: .running,
                    caughtUp: true,
                    turn: .init(
                        turnID: "step-282", // same USER_INPUT turnID resumed after background wakeup!
                        phase: .tool,
                        startedAt: now.addingTimeInterval(30),
                        updatedAt: now.addingTimeInterval(120),
                        tokens: 8_500,
                        text: "运行完整测试",
                        steps: [.init(id: "s300-0", title: "运行完整测试", status: "running")]
                    )
                )
            ]
        )
        runtime.consume(resumedTurnScan, now: now.addingTimeInterval(120))
        let resumedRow = runtime.rows.first { $0.id == "agy:live-esc" }
        expect(resumedRow?.phase == .usingTool && resumedRow?.isRetainedReceipt == false,
               "same turnID resumed after background wakeup clears settledTurns and re-activates island row")
        compactCheckModel.sessions = [resumedRow!]
        expect(!compactCheckModel.showsCompactQuota, "compact island switches back from idle banner to active task")
        // Settle resumed row cleanly before benchmark
        let settledResumedScan = AntigravityScanResult(
            usage: historicalScan.usage,
            sessions: [
                AntigravitySessionRecord(
                    id: "live-esc",
                    surface: .cli,
                    cwd: "/Users/dev/PulseProject",
                    title: "Test Esc",
                    model: "gemini-4-carbon-medium",
                    totalTokens: 9_000,
                    isSubagent: false,
                    isLockedLive: true,
                    summaryBusy: false,
                    summaryStatus: .idle(modifiedAt: now.addingTimeInterval(125)),
                    caughtUp: true,
                    turn: .init(turnID: "step-282", phase: .completed, startedAt: now.addingTimeInterval(30), updatedAt: now.addingTimeInterval(125), tokens: 9_000, text: "完成", steps: [])
                )
            ]
        )
        runtime.consume(settledResumedScan, now: now.addingTimeInterval(125))

        // 3. StatusLine quota & IslandUsagePresentation + 4-provider switcher layout check
        let statusPayload = try JSONSerialization.data(withJSONObject: [
            "capturedAt": now.timeIntervalSince1970,
            "plan_tier": "Google AI Ultra",
            "credits": 120,
            "useG1Credits": true,
            "quota": [
                "gemini-5h": ["remaining_fraction": 0.72, "reset_in_seconds": 10_800],
                "gemini-weekly": ["remaining_fraction": 0.85, "reset_in_seconds": 400_000],
                "3p-5h": ["remaining_fraction": 1.0, "reset_in_seconds": 18_000],
                "3p-weekly": ["remaining_fraction": 0.94, "reset_in_seconds": 500_000]
            ]
        ])
        runtime.receive(.init(eventID: "sl-1", kind: "statusLine", awaitsDecision: false, payload: statusPayload), receivedAt: now)
        expect(runtime.quota?.resolvedPlan == "Google AI Ultra" && runtime.quota?.aiCredits == 120, "runtime updated quota from statusLine")
        expect(runtime.quota?.windows.contains(where: { $0.id == "3p-5h" && $0.title == "合作模型 5 小时" }) == true, "3p-5h classified as partner 5h pool")

        let presentation = IslandUsagePresentation.antigravity(
            usage: historicalScan.usage,
            quota: runtime.quota,
            statusLineEnabled: true,
            now: now
        )
        expect(runtime.quota?.windows.count == 4 && presentation.quotas.count == 2 && presentation.quotas.first?.remainingPercent == 72, "runtime retains all 4 pools while island dashboard shows top 2")
        expect(presentation.cost.total == nil && presentation.cost.totalIsLowerBound, "all-unpriced day reports nil total rather than fake $0")
        expect(!presentation.supportsReset, "Antigravity does not expose Codex reset ticket")

        let islandModel = ActivityIslandViewModel()
        islandModel.grokEnabled = true
        islandModel.antigravityEnabled = true
        islandModel.updateClaudeEnabled(true)
        islandModel.selectUsageProvider(.antigravity)
        expect(islandModel.usageProvider == .antigravity, "Antigravity selectable when enabled")
        let switchHost = NSHostingView(rootView: IslandUsageProviderSwitch(model: islandModel))
        expect(switchHost.fittingSize.width == 374 && switchHost.fittingSize.height == 28, "4-provider switch fits within 430pt island")

        // 3b. Benchmark opening ActivityIslandUsageDashboard (clicking top-left quota capsule)
        islandModel.presentation = .expanded
        islandModel.sessions = runtime.rows
        islandModel.antigravityStatusLineEnabled = true
        islandModel.antigravityQuota = runtime.quota
        islandModel.antigravityUsage = historicalScan.usage
        islandModel.metrics = ActivityIslandPanelMetrics(
            rowCount: 1,
            availableSize: CGSize(width: 1440, height: 900),
            usagePage: false,
            reservesUsagePage: true
        )
        let islandExpandHost = NSHostingView(rootView: ActivityIslandView(model: islandModel, compact: false))
        let benchWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        benchWindow.contentView = islandExpandHost
        islandExpandHost.layoutSubtreeIfNeeded()
        let openStart = CFAbsoluteTimeGetCurrent()
        islandModel.showsUsagePage = true
        islandModel.metrics = ActivityIslandPanelMetrics(
            rowCount: 1,
            availableSize: CGSize(width: 1440, height: 900),
            usagePage: true,
            reservesUsagePage: true
        )
        islandExpandHost.layoutSubtreeIfNeeded()
        let openElapsedMs = (CFAbsoluteTimeGetCurrent() - openStart) * 1000.0
        benchWindow.contentView = nil
        print(String(format: "Island usage dashboard open latency: %.2f ms", openElapsedMs))
        expect(openElapsedMs < 120.0, "expanding usage dashboard completes well within responsive budget")

        // 3c. Completed receipt duration lock + 60s expiry without 62s zombie resurrection (regression for 11:09:57 bug)
        let zombieStart = now.addingTimeInterval(200)
        let zombieActiveScan = AntigravityScanResult(
            usage: historicalScan.usage,
            sessions: [
                AntigravitySessionRecord(
                    id: "live-zombie",
                    surface: .cli,
                    cwd: "/Users/dev/PulseProject",
                    title: "给你我所有的权限，帮我制作 Agent Pulse 的 2.5D 宣传片",
                    model: "gemini-4-carbon-high",
                    totalTokens: 1_500_000,
                    isSubagent: false,
                    isLockedLive: true,
                    summaryBusy: true,
                    summaryStatus: .running,
                    caughtUp: true,
                    turn: .init(
                        turnID: "step-262",
                        phase: .tool,
                        startedAt: zombieStart,
                        updatedAt: zombieStart.addingTimeInterval(90),
                        tokens: 1_500_000,
                        text: "验证后台预览服务",
                        steps: [.init(id: "s269-0", title: "Verify HTTP 200 on Studio", status: "running")]
                    )
                )
            ]
        )
        runtime.consume(zombieActiveScan, now: zombieStart.addingTimeInterval(91))
        expect(runtime.rows.contains(where: { $0.id == "agy:live-zombie" && $0.phase == .usingTool }),
               "zombie test turn observed active")

        // Out-of-order Stop followed 2ms later by PostInvocation must NOT clear settled state or revive .working
        let stopHookPayload = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "Stop",
            "conversationId": "live-zombie",
            "terminationReason": "NO_TOOL_CALL"
        ])
        let latePostPayload = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "PostInvocation",
            "conversationId": "live-zombie"
        ])
        let turnRealEnd = zombieStart.addingTimeInterval(135) // 02:15 real duration
        let zombieDoneScan = AntigravityScanResult(
            usage: historicalScan.usage,
            sessions: [
                AntigravitySessionRecord(
                    id: "live-zombie",
                    surface: .cli,
                    cwd: "/Users/dev/PulseProject",
                    title: "给你我所有的权限，帮我制作 Agent Pulse 的 2.5D 宣传片",
                    model: "gemini-4-carbon-high",
                    totalTokens: 1_500_000,
                    isSubagent: false,
                    isLockedLive: false,
                    summaryBusy: false,
                    caughtUp: true,
                    turn: .init(
                        turnID: "step-262",
                        phase: .completed,
                        startedAt: zombieStart,
                        updatedAt: turnRealEnd,
                        tokens: 1_500_000,
                        text: "已经全部在后台启动并核验可访问，直接点下面链接即可预览：",
                        steps: [.init(id: "s269-0", title: "Verify HTTP 200 on Studio", status: "completed")]
                    )
                )
            ]
        )
        // First evaluate natural transcript completion (without Stop hook) across 0s -> 16s -> 60s -> 62s -> 11h09m57s:
        let detectedAt = turnRealEnd.addingTimeInterval(1) // t_detect = zombieStart + 136
        runtime.consume(zombieDoneScan, now: detectedAt)
        if let completedZombie = runtime.rows.first(where: { $0.id == "agy:live-zombie" }) {
            expect(completedZombie.phase == .completed && !completedZombie.isRetainedReceipt,
                   "completed turn starts as fresh receipt")
            expect(completedZombie.updatedAt == turnRealEnd,
                   "completed row updatedAt locks to transcript turn.updatedAt instead of wall clock")
            expect(ActivityIslandFocusCard.clockTitle(row: completedZombie, at: detectedAt.addingTimeInterval(40_197)) == "02:15"
                   && completedZombie.durationTitle(at: completedZombie.updatedAt) == "2m",
                   "completed focus card clock reflects exact 02:15 turn runtime regardless of wall clock")
        } else {
            expect(false, "completed receipt must exist at t=0s")
        }

        runtime.consume(zombieDoneScan, now: detectedAt.addingTimeInterval(16))
        if let retainedZombie = runtime.rows.first(where: { $0.id == "agy:live-zombie" }) {
            expect(retainedZombie.isRetainedReceipt && retainedZombie.updatedAt == turnRealEnd,
                   "at t=16s receipt becomes retained while keeping fixed updatedAt")
        } else {
            expect(false, "retained receipt must still exist in expanded rail at t=16s")
        }

        // At t = 60s: receipt expires and leaves rows
        runtime.consume(zombieDoneScan, now: detectedAt.addingTimeInterval(60))
        expect(!runtime.rows.contains(where: { $0.id == "agy:live-zombie" }),
               "completed receipt removed promptly at 60s")

        // At t = 62s, 124s, and 11h09m57s later: must NEVER resurrect or drift updatedAt!
        for offset: TimeInterval in [62, 124, 40_197] {
            runtime.consume(zombieDoneScan, now: detectedAt.addingTimeInterval(offset))
            expect(runtime.rows.isEmpty,
                   "expired completed turn stays gone at +\(Int(offset))s without 62s zombie loop")
        }

        // Verify out-of-order PostInvocation arriving 2ms after Stop also stays terminal and expires cleanly
        let hookTurnStart = zombieStart.addingTimeInterval(500)
        let preInvPayload = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "PreInvocation",
            "conversationId": "live-hook-order",
            "cwd": "/Users/dev/PulseProject",
            "lastUserInput": "测试乱序 Hook"
        ])
        runtime.receive(.init(eventID: "ho-1", kind: "hook", awaitsDecision: false, payload: preInvPayload), receivedAt: hookTurnStart)
        expect(runtime.rows.contains(where: { $0.id == "agy:live-hook-order" && $0.phase == .working }),
               "hook-only turn starts working")
        let stopOrderPayload = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "Stop",
            "conversationId": "live-hook-order",
            "terminationReason": "NO_TOOL_CALL"
        ])
        let latePostOrderPayload = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "PostInvocation",
            "conversationId": "live-hook-order"
        ])
        runtime.receive(.init(eventID: "ho-2", kind: "hook", awaitsDecision: false, payload: stopOrderPayload), receivedAt: hookTurnStart.addingTimeInterval(10))
        runtime.receive(.init(eventID: "ho-3", kind: "hook", awaitsDecision: false, payload: latePostOrderPayload), receivedAt: hookTurnStart.addingTimeInterval(10.002))
        expect(!runtime.rows.contains(where: { $0.id == "agy:live-hook-order" && $0.phase.isActive }),
               "late PostInvocation after Stop never revives active working state")
        let _ = (stopHookPayload, latePostPayload)

        // 4. Glass Panel (296pt) multi-provider header & AntigravityGlanceContent never overflow horizontally
        let twoRowHeader = VStack(spacing: 6) {
            HStack(spacing: 6) {
                CodexMark(size: 20)
                Text("Agent Pulse").font(.system(size: 13, weight: .semibold)).fixedSize()
                Spacer(minLength: 6)
                Text("账号 6 · Pro200").font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            GlanceProviderSwitch(
                selection: .constant(.antigravity),
                available: [.codex, .claude, .grok, .antigravity],
                fullWidth: true,
                providerTones: [.codex: .critical, .claude: .calm, .grok: .calm, .antigravity: .calm],
                providerRemaining: [.codex: 0, .claude: 78, .grok: 95, .antigravity: 93]
            )
        }
        .padding(.horizontal, GlanceLayout.contentInset)
        .frame(width: GlanceLayout.width, height: 88)
        let headerHost = NSHostingView(rootView: twoRowHeader)
        headerHost.layoutSubtreeIfNeeded()
        expect(headerHost.fittingSize.width <= GlanceLayout.width + 0.5 && headerHost.fittingSize.height <= 88.5,
               "2-row 4-provider telemetry tile Glance header fits strictly within 296x88pt")

        let brandBounds = CGRect(x: 0, y: 0, width: 13, height: 13)
        for (name, path) in [
            ("Codex", CodexBrandMarkShape().path(in: brandBounds)),
            ("Claude", ClaudeMarkShape().path(in: brandBounds)),
            ("Grok", GrokBrandMarkShape().path(in: brandBounds)),
            ("Antigravity", AntigravityMarkShape().path(in: brandBounds))
        ] {
            expect(!path.isEmpty && brandBounds.contains(path.boundingRect),
                   "\(name) official vector mark produces non-empty path strictly within 13pt bounds")
        }

        let glanceBody = AntigravityGlanceContent(
            runtime: runtime,
            now: now,
            weatherColor: GlanceTone.calm.color,
            showsInlinePlanBadge: false,
            showQuota: true,
            showCost: true,
            showCreditBalance: true,
            showActivity: true,
            showDaily: true,
            showMonth: true,
            metric: .constant("token")
        )
        .padding(.horizontal, GlanceLayout.contentInset)
        .frame(width: GlanceLayout.width)
        let glanceHost = NSHostingView(rootView: glanceBody)
        glanceHost.layoutSubtreeIfNeeded()
        expect(glanceHost.fittingSize.width <= GlanceLayout.width + 0.5 && glanceHost.fittingSize.height > 200,
               "AntigravityGlanceContent fits strictly within 296pt Glass Panel")

        let viewHost = NSHostingView(rootView: AntigravityView(runtime: runtime).frame(width: 760, height: 600))
        viewHost.layoutSubtreeIfNeeded()
        expect(viewHost.fittingSize.width > 0, "AntigravityView renders cleanly")

        // 5. OneNative agy-statusline live cache decoding, plan metadata carry-forward & updatedAt max
        let oneNativeDir = tempRoot.appendingPathComponent("one-native-agy", isDirectory: true)
        try FileManager.default.createDirectory(at: oneNativeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let newerObserved = now.addingTimeInterval(180)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oneNativeSnapshot: [String: Any] = [
            "version": 1,
            "pid": Int(getpid()),
            "observed_at": isoFormatter.string(from: newerObserved),
            "facts": [
                "conversation_id": "51e9d780-22ce-4a14-a270-5ab88bdc9f09",
                "cwd": "/tmp",
                "agent_state": "thinking",
                "model": "Gemini 4 Carbon (Medium)",
                "quota": [
                    "gemini-5h": [
                        "remaining_fraction": 0.9174,
                        "resets_at": Int(newerObserved.addingTimeInterval(14_400).timeIntervalSince1970)
                    ],
                    "gemini-weekly": [
                        "remaining_fraction": 0.9396,
                        "resets_at": Int(newerObserved.addingTimeInterval(500_000).timeIntervalSince1970)
                    ]
                ]
            ]
        ]
        let oneNativeFile = oneNativeDir.appendingPathComponent("\(getpid()).json")
        let oneNativeData = try JSONSerialization.data(withJSONObject: oneNativeSnapshot)
        try oneNativeData.write(to: oneNativeFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oneNativeFile.path)

        let oneNativeInstaller = AntigravityInstaller(
            socketURL: tempRoot.appendingPathComponent("on-bridge.sock"),
            authenticationToken: "token-on",
            geminiDirectory: geminiDir,
            supportDirectory: tempRoot.appendingPathComponent("on-support", isDirectory: true),
            helperURL: URL(fileURLWithPath: helperPath),
            oneNativeStatusLineDirectories: [oneNativeDir]
        )
        try FileManager.default.createDirectory(at: oneNativeInstaller.statusLineSnapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try statusPayload.write(to: oneNativeInstaller.statusLineSnapshotURL)
        let oneNativeDefaults = UserDefaults(suiteName: "test.ag.onenative.\(UUID().uuidString)")!
        oneNativeDefaults.set(true, forKey: "antigravity.enabled")
        let oneNativeRuntime = AntigravityRuntime(
            defaults: oneNativeDefaults,
            installer: oneNativeInstaller,
            scanner: scanner
        )
        oneNativeRuntime.refresh()
        expect(oneNativeRuntime.quota?.windows.first(where: { $0.id == "gemini-5h" })?.remainingPercent == 92,
               "newer OneNative agy-statusline quota overrides older persisted snapshot")
        expect(oneNativeRuntime.quota?.resolvedPlan == "Google AI Ultra" && oneNativeRuntime.quota?.aiCredits == 120,
               "plan_tier and AI Credits carried forward from persisted statusLine snapshot")

        let fresherUsageScan = AntigravityScanResult(
            usage: .init(
                days: historicalScan.usage.days,
                lifetimeTokens: historicalScan.usage.lifetimeTokens,
                sessionCount: historicalScan.usage.sessionCount,
                complete: true,
                unpricedModels: historicalScan.usage.unpricedModels,
                updatedAt: newerObserved.addingTimeInterval(60)
            ),
            sessions: []
        )
        let freshPresentation = IslandUsagePresentation.antigravity(
            usage: fresherUsageScan.usage,
            quota: oneNativeRuntime.quota,
            statusLineEnabled: true,
            now: newerObserved.addingTimeInterval(60)
        )
        expect(freshPresentation.updatedAt == fresherUsageScan.usage.updatedAt,
               "footer updatedAt uses max(quota.capturedAt, usage.updatedAt) instead of sticking to older quota")

        // 6. Rolled-over 5h window detection + cross-provider warning dot switcher + Grok Weather Glass fit
        let postResetNow = newerObserved.addingTimeInterval(14_600)
        expect(oneNativeRuntime.quota?.rolledOverGeminiFiveHour(at: postResetNow, staleCutoff: 20_000)?.id == "gemini-5h",
               "5h Gemini window crossing resetsAt after capture is surfaced as rolled-over 100% rather than silently dropped")

        let warningSwitch = GlanceProviderSwitch(
            selection: .constant(.antigravity),
            available: [.codex, .claude, .grok, .antigravity],
            fullWidth: true,
            activeColor: GlanceTone.calm.color,
            providerTones: [.codex: .critical, .claude: .tight, .grok: .calm, .antigravity: .calm]
        )
        .padding(.horizontal, GlanceLayout.contentInset)
        .frame(width: GlanceLayout.width)
        let warningSwitchHost = NSHostingView(rootView: warningSwitch)
        warningSwitchHost.layoutSubtreeIfNeeded()
        expect(warningSwitchHost.fittingSize.width <= GlanceLayout.width + 0.5,
               "4-provider Glance switch with warning dots fits strictly within 296pt")

        let grokDefaults = UserDefaults(suiteName: "test.ag.grokglance.\(UUID().uuidString)")!
        let grokRuntime = GrokRuntime(defaults: grokDefaults)
        let grokGlance = GrokGlanceContent(
            runtime: grokRuntime,
            now: now,
            showQuota: true,
            showCost: true,
            showActivity: true,
            showDaily: true,
            showMonth: true,
            metric: .constant("token"),
            weatherColor: GlanceTone.calm.color,
            showsInlinePlanBadge: false,
            showCreditBalance: true
        )
        .padding(.horizontal, GlanceLayout.contentInset)
        .frame(width: GlanceLayout.width)
        let grokGlanceHost = NSHostingView(rootView: grokGlance)
        grokGlanceHost.layoutSubtreeIfNeeded()
        expect(grokGlanceHost.fittingSize.width <= GlanceLayout.width + 0.5,
               "Weather-styled GrokGlanceContent fits strictly within 296pt")

        let rowCheck = SettingsRow(
            symbol: "gauge.with.dots.needle.33percent",
            title: "主额度窗口",
            detail: "5 小时、每周及其他官方可用额度窗口（覆盖 Codex、Claude、Grok 与 Antigravity）。"
        ) {
            Toggle("主额度窗口", isOn: .constant(true)).labelsHidden().toggleStyle(PanelSettingsToggleStyle())
        }
        .frame(width: 480)
        let rowCheckHost = NSHostingView(rootView: rowCheck)
        rowCheckHost.layoutSubtreeIfNeeded()
        expect(rowCheckHost.fittingSize.height < 90,
               "long two-line SettingsRow keeps Toggle inline on the right instead of stacking below")

        // 6. End-to-end PreToolUse interactive ask_question + tool approval round-trips
        func spawnHelperHook(_ payload: [String: Any]) throws -> Task<Data, Error> {
            let inputData = try JSONSerialization.data(withJSONObject: payload)
            let helperURL = runtime.installer.installedHelperURL
            let routePath = runtime.installer.routeURL.path
            return Task.detached {
                let proc = Process()
                proc.executableURL = helperURL
                proc.arguments = ["--antigravity-hook", "--configuration", routePath]
                let inPipe = Pipe()
                let outPipe = Pipe()
                proc.standardInput = inPipe
                proc.standardOutput = outPipe
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                try inPipe.fileHandleForWriting.write(contentsOf: inputData)
                try inPipe.fileHandleForWriting.close()
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                return out
            }
        }

        // 6a. ask_question answered in Dynamic Island
        let qTask = try spawnHelperHook([
            "hookEventName": "PreToolUse",
            "conversationId": "conv-interactive",
            "cwd": "/Users/dev/AgentPulse",
            "workspacePaths": ["/Users/dev/AgentPulse"],
            "transcriptPath": "/Users/dev/.gemini/antigravity/brain/conv-interactive/transcript.jsonl",
            "lastUserInput": "帮我重构面板",
            "toolCall": [
                "id": "call-ask-1",
                "name": "ask_question",
                "args": [
                    "questions": [
                        [
                            "question": "请选择布局方案",
                            "options": ["(Recommended) 方案 B", "方案 A"],
                            "is_multi_select": false
                        ]
                    ]
                ]
            ]
        ])
        for _ in 0..<60 where runtime.requests.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(runtime.requests.count == 1 && runtime.requests.first?.isQuestion == true,
               "ask_question registered as pending interactive question")
        expect(runtime.rows.contains(where: { $0.id == "agy:conv-interactive" && $0.phase == .waitingApproval && $0.waitReason == .userInput }),
               "Dynamic Island row enters waitingApproval userInput state for ask_question")
        let qReq = runtime.requests[0]
        expect(runtime.respond(qReq.id, choice: .answer, answers: [qReq.questions[0].id: "(Recommended) 方案 B"]),
               "island answer submission accepted")
        let qOutData = try await qTask.value
        let qOutText = String(decoding: qOutData, as: UTF8.self)
        let qOutObj = try JSONSerialization.jsonObject(with: qOutData) as? [String: Any]
        if qOutObj?["decision"] as? String != "deny" {
            print("UNEXPECTED qOutText:", qOutText.debugDescription)
        }
        expect(qOutObj?["decision"] as? String == "deny" && (qOutObj?["reason"] as? String)?.contains("(Recommended) 方案 B") == true,
               "ask_question answer returned to Antigravity turn via structured reason")

        // 6b. Sensitive run_command approved once in Dynamic Island
        let cmdTask = try spawnHelperHook([
            "hookEventName": "PreToolUse",
            "conversationId": "conv-interactive",
            "cwd": "/Users/dev/AgentPulse",
            "workspacePaths": ["/Users/dev/AgentPulse"],
            "transcriptPath": "/Users/dev/.gemini/antigravity/brain/conv-interactive/transcript.jsonl",
            "toolCall": [
                "id": "call-cmd-1",
                "name": "run_command",
                "args": [
                    "CommandLine": "git push origin main",
                    "toolSummary": "Push main branch"
                ]
            ]
        ])
        for _ in 0..<60 where runtime.requests.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(runtime.requests.count == 1 && runtime.requests.first?.isQuestion == false,
               "sensitive run_command registered as pending tool approval")
        expect(runtime.rows.contains(where: { $0.id == "agy:conv-interactive" && $0.phase == .waitingApproval && $0.waitReason == .approval }),
               "Dynamic Island row enters waitingApproval approval state for sensitive command")
        let cmdReq = runtime.requests[0]
        expect(runtime.respond(cmdReq.id, choice: .approveOnce), "approveOnce accepted")
        let cmdOutData = try await cmdTask.value
        let cmdOutObj = try JSONSerialization.jsonObject(with: cmdOutData) as? [String: Any]
        expect(cmdOutObj?["decision"] as? String == "auto_approve",
               "explicit approveOnce outputs auto_approve to Antigravity")

        // Disable cleans up
        runtime.configure(enabled: false, hooks: true, statusLine: true)
        for _ in 0..<40 where runtime.configuring {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        expect(!runtime.enabled && runtime.rows.isEmpty && runtime.quota == nil, "disable clears runtime state")

        print("Antigravity runtime: \(checks)/\(checks) passed")
    }
}
