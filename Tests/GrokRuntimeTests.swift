import AppKit
import SwiftUI

@main
@MainActor
struct GrokRuntimeTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !value() { fatalError("Grok runtime: " + message) }
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "CodexPulse.GrokTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "grok.enabled")
        let runtime = GrokRuntime(home: directory, defaults: defaults)
        let now = Date()
        var turn = GrokTurnState(promptID: "turn1", phase: .completed, startedAt: now.addingTimeInterval(-10), updatedAt: now, tokens: 50)
        func scan(_ turn: GrokTurnState, live: Bool = true, caughtUp: Bool = true) -> GrokSessionScan {
            .init(sessions: [.init(id: "session1", cwd: "/fixture/project", title: "测试任务", model: "grok-test",
                turn: turn, caughtUp: caughtUp, totalTokens: 50)],
                usage: .init(days: [.init(date: Calendar.current.startOfDay(for: now), tokens: 50, cost: 0.1)], complete: true, sessionCount: 1, updatedAt: now),
                liveIDs: live ? ["session1"] : [])
        }
        runtime.consume(scan(turn), now: now)
        expect(runtime.rows.isEmpty, "cold completed history never creates receipt")
        turn.phase = .working; turn.promptID = "turn2"
        runtime.consume(scan(turn, live: false), now: now)
        expect(runtime.rows.isEmpty, "unverified process cannot create live task")
        runtime.consume(scan(turn, caughtUp: false), now: now)
        expect(runtime.rows.isEmpty, "incomplete tail cannot create live task")
        runtime.consume(scan(turn), now: now)
        expect(runtime.rows.count == 1 && runtime.rows[0].provider == "Grok CLI" && runtime.rows[0].phase == .working, "verified live task appears independently")
        let previous = runtime.rows
        turn.phase = .completed; turn.updatedAt = now.addingTimeInterval(1)
        runtime.consume(scan(turn), now: now.addingTimeInterval(1))
        expect(runtime.rows.first?.phase == .completed && runtime.rows.first?.suppressCompletion == false, "observed terminal gets completion feedback")
        expect(ActivitySessionSnapshot.newlyCompleted(in: runtime.rows, previous: previous) != nil, "existing celebration pipeline recognizes Grok completion")
        expect(runtime.rows[0].tokenUsage?.sessionID == "grok:session1", "token identity is namespaced")
        let completed = runtime.rows
        runtime.consume(scan(turn), now: now.addingTimeInterval(2))
        expect(ActivitySessionSnapshot.newlyCompleted(in: runtime.rows, previous: completed) == nil, "duplicate completion does not replay")
        runtime.consume(scan(turn), now: now.addingTimeInterval(62))
        expect(runtime.rows.isEmpty, "receipt expires after one minute")
        var prePromptTurn = GrokTurnState(promptID: nil, phase: .working, startedAt: now.addingTimeInterval(62.5), updatedAt: now.addingTimeInterval(62.5))
        runtime.consume(scan(prePromptTurn), now: now.addingTimeInterval(62.5))
        expect(runtime.rows.count == 1 && runtime.rows.first?.phase == .working && runtime.rows.first?.turnID?.hasPrefix("pending-") == true,
               "live turn before first thought chunk appears immediately with pending turn ID")
        let prePromptRows = runtime.rows
        prePromptTurn.promptID = "turn-promoted"; prePromptTurn.phase = .completed; prePromptTurn.updatedAt = now.addingTimeInterval(62.8); prePromptTurn.tokens = 120
        runtime.consume(scan(prePromptTurn), now: now.addingTimeInterval(62.8))
        expect(runtime.rows.count == 1 && runtime.rows.first?.turnID == "turn-promoted" && runtime.rows.first?.phase == .completed && runtime.rows.first?.suppressCompletion == false,
               "pending turn promotes cleanly to authoritative prompt ID without ghost ended receipt")
        expect(ActivitySessionSnapshot.newlyCompleted(in: runtime.rows, previous: prePromptRows) != nil,
               "promoted pre-prompt turn triggers completion celebration")
        runtime.consume(scan(prePromptTurn), now: now.addingTimeInterval(125))
        expect(runtime.rows.isEmpty, "promoted turn receipt expires cleanly")
        turn.phase = .tool; turn.promptID = "turn3"; turn.steps = [.init(id: "tool", title: "Search", status: "pending")]
        runtime.consume(scan(turn), now: now.addingTimeInterval(63))
        expect(runtime.rows.first?.phase == .usingTool && runtime.rows.first?.recentSteps.first?.state == .running, "pending tool is not a fabricated approval")
        let active = runtime.rows
        runtime.consume(scan(turn, live: false), now: now.addingTimeInterval(64))
        expect(runtime.rows.first?.phase == .ended && runtime.rows.first?.recentSteps.first?.state == .ended, "process loss ends task neutrally")
        expect(ActivitySessionSnapshot.newlyCompleted(in: runtime.rows, previous: active) == nil, "process loss never claims success")
        let later = now.addingTimeInterval(200)
        turn.promptID = "turn4"; turn.phase = .working; turn.updatedAt = later.addingTimeInterval(-300)
        runtime.consume(scan(turn), now: later)
        turn.phase = .completed; turn.updatedAt = later.addingTimeInterval(-120)
        runtime.consume(scan(turn), now: later.addingTimeInterval(1))
        expect(runtime.rows.isEmpty, "late-read old completion does not become a fresh receipt")
        let q = GrokQuotaSnapshot(usedPercent: 25, startsAt: now.addingTimeInterval(-3600), resetsAt: now.addingTimeInterval(86400),
            periodType: "USAGE_PERIOD_TYPE_WEEKLY", plan: "Fixture", prepaidCents: 100, sharedPool: true, capturedAt: now)
        let projected = IslandUsagePresentation.grok(usage: runtime.usage, quota: q, failed: false, status: "", now: now)
        expect(projected.provider == .grok && projected.quotas[0].remainingPercent == 75 && !projected.supportsReset, "Grok quota and reset restrictions")
        expect(projected.metrics[1].tokens == 50 && projected.cost.total == 0.1, "Grok history projection is separate")
        let failed = IslandUsagePresentation.grok(usage: nil, quota: q, failed: true, status: "超时", now: now)
        expect(failed.quotas[0].freshness.isStale && failed.metrics[0].tokens == nil, "failure marks old observation; no Codex fallback")
        let expired = IslandUsagePresentation.grok(usage: nil, quota: q, failed: false, status: "", now: now.addingTimeInterval(86401))
        expect(expired.quotas[0].remainingPercent == nil, "expired Grok quota hidden")
        expect(GlanceProvider.resolve("grok", claudeEnabled: true, grokEnabled: true) == .grok, "menu selects enabled Grok")
        expect(GlanceProvider.resolve("grok", claudeEnabled: true) == .codex, "disabled Grok falls back to Codex")
        let model = ActivityIslandViewModel(); model.grokEnabled = true; model.selectUsageProvider(.grok); model.updateClaudeEnabled(false)
        expect(model.usageProvider == .grok, "disabling Claude preserves selected Grok")
        model.resetBusy = true; model.selectUsageProvider(.codex)
        expect(model.usageProvider == .grok, "reset busy still prevents provider changes")
        model.resetBusy = false; model.grokEnabled = false; model.selectUsageProvider(.codex); model.selectUsageProvider(.grok)
        expect(model.usageProvider == .codex, "disabled Grok cannot be selected")
        runtime.configure(enabled: false)
        expect(runtime.rows.isEmpty && runtime.usage == nil && !runtime.refreshing, "disable clears all Grok state")
        runtime.consume(scan(turn))
        expect(runtime.rows.isEmpty, "late scans after disable ignored")

        defaults.set(true, forKey: "grok.enabled")
        let interactive = GrokRuntime(home: directory, defaults: defaults), sessionID = UUID().uuidString
        var pendingTurn = GrokTurnState(promptID: "pending-turn", phase: .tool, startedAt: now, updatedAt: now)
        pendingTurn.steps = [.init(id: "ask", title: "AskQuestion", status: "pending")]
        interactive.consume(.init(sessions: [.init(id: sessionID, cwd: "/fixture", title: "问题任务", model: "grok-test", turn: pendingTurn, caughtUp: true, totalTokens: 0)],
            usage: .init(days: [], complete: true, sessionCount: 1, updatedAt: now), liveIDs: [sessionID]))
        let question = GrokQuestionRequest.decode(["id": 1, "method": "_x.ai/ask_user_question", "params": [
            "sessionId": sessionID, "toolCallId": "ask", "questions": [["question": "选择？", "options": [["label": "A, B"], ["label": "C"]], "multiSelect": true]]]], epoch: UUID(), turnID: "pending-turn")!
        interactive.consumeShared(.init(revision: 100, requests: [question]))
        expect(interactive.rows.first?.statusTitle == "待回复" && interactive.rows.first?.replyRequestIDs == [question.id], "authoritative shared question becomes waiting-input island row")
        let permission = GrokQuestionRequest.decode(["id": 2, "method": "session/request_permission", "params": [
            "sessionId": sessionID, "toolCall": ["toolCallId": "ask", "title": "运行测试", "rawInput": ["command": "echo fixture"]],
            "options": [["optionId": "allow-native", "kind": "allow_once"], ["optionId": "deny-native", "kind": "reject_once"]]]], epoch: UUID(), turnID: "pending-turn")!
        interactive.consumeShared(.init(revision: 101, requests: [permission]))
        expect(interactive.rows.first?.statusTitle == "待确认" && interactive.rows.first?.suppressCompletion == true, "permission uses approval state without completion")
        interactive.consumeShared(.init(revision: 102))
        expect(interactive.rows.first?.phase == .usingTool && interactive.questions.isEmpty, "resolved interaction returns to current tool state")
        interactive.consumeShared(.init(revision: 101, requests: [permission]))
        expect(interactive.questions.isEmpty, "out-of-order main actor callback cannot resurrect old permission")
        var card = IslandApprovalContent(id: question.id, provider: "Grok CLI", title: "需要回答", summary: "")
        card.questions = [.init(id: "选择？", title: "选择？", options: ["A, B", "C"], allowsText: true, multiSelect: true)]
        card.submitDraft = { _, _ in "fixture" }
        expect(card.hasInlineControls && card.presentation(privacy: true).submitDraft == nil, "typed draft submit respects privacy")
        let draft = IslandAnswerDraft(); draft.toggle("A, B", for: "选择？", orderedOptions: ["A, B", "C"]); draft.toggle("C", for: "选择？", orderedOptions: ["A, B", "C"])
        expect(draft.selections["选择？"] == ["A, B", "C"], "island draft retains typed multi-select array")
        interactive.configure(enabled: false)
        expect(interactive.questions.isEmpty && interactive.rows.isEmpty, "disable clears pending controls without answering")
        defaults.set(true, forKey: "grok.enabled")
        let setupHome = URL(fileURLWithPath: "/tmp/gprs-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: setupHome) }
        let setupRace = GrokRuntime(home: setupHome, defaults: defaults)
        setupRace.enableAutomatic(); setupRace.configure(enabled: false)
        let setupEnd = Date().addingTimeInterval(5)
        while setupRace.automaticConfiguring && Date() < setupEnd { try await Task.sleep(nanoseconds: 20_000_000) }
        expect(!setupRace.enabled && setupRace.automaticReady, "completed setup cannot override a later explicit disable")
        defaults.set(true, forKey: "grok.enabled")
        let diagnosticHome = directory.appendingPathComponent("diagnostic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: diagnosticHome, withIntermediateDirectories: true)
        try Data("[cli]\nuse_leader=true\n".utf8).write(to: diagnosticHome.appendingPathComponent("config.toml"))
        let diagnosticID = UUID().uuidString
        try JSONSerialization.data(withJSONObject: [["session_id": diagnosticID, "pid_start": (now.timeIntervalSince1970 - 3600) * 1_000_000]])
            .write(to: diagnosticHome.appendingPathComponent("active_sessions.json"))
        let diagnostic = GrokRuntime(home: diagnosticHome, defaults: defaults)
        diagnostic.consume(.init(sessions: [], usage: .init(days: [], complete: true, sessionCount: 0, updatedAt: now), liveIDs: [], registeredIDs: [diagnosticID]))
        expect(diagnostic.questionStatus.contains("/new") && diagnostic.questionStatus.contains("退出 Grok CLI"), "old standalone process is explicitly distinguished from a new session")
        diagnostic.consumeShared(.init(revision: 100, connected: true, status: "共享问答已连接"))
        expect(diagnostic.questionStatus == "共享问答已连接", "real connection takes precedence over old registry entries")
        diagnostic.configure(enabled: false)
        expect(diagnostic.questionStatus == "Grok 监控已关闭", "disabled monitor never claims a live question connection")

        // OneNative gives each terminal launch its own `leader-*.sock`; Pulse follows every one of them.
        let leaders = URL(fileURLWithPath: "/tmp/gpl-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: leaders, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: leaders) }
        func bindSocket(_ name: String) -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(leaders.appendingPathComponent(name).path.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            return fd
        }
        let bound = ["leader.sock", "leader-onenative-AAAA-1.sock", "leader-onenative-BBBB-2.sock", "other.sock"].map(bindSocket)
        defer { bound.forEach { close($0) } }
        try Data("not a socket".utf8).write(to: leaders.appendingPathComponent("leader-fake.sock"))
        try FileManager.default.createSymbolicLink(at: leaders.appendingPathComponent("leader-link.sock"),
                                                   withDestinationURL: leaders.appendingPathComponent("leader.sock"))
        expect(GrokLauncher.sharedSockets(home: leaders).map(\.lastPathComponent)
               == ["leader-onenative-AAAA-1.sock", "leader-onenative-BBBB-2.sock", "leader.sock"],
               "only same-user leader sockets by Grok's naming are followed; files, links and other names are not")
        defaults.set(true, forKey: "grok.enabled")
        let multi = GrokRuntime(home: leaders, defaults: defaults)
        let first = UUID().uuidString, second = UUID().uuidString
        var turnA = GrokTurnState(promptID: "turn-a", phase: .tool, startedAt: now, updatedAt: now); turnA.steps = []
        var turnB = GrokTurnState(promptID: "turn-b", phase: .tool, startedAt: now, updatedAt: now); turnB.steps = []
        multi.consume(.init(sessions: [.init(id: first, cwd: "/a", title: "A", model: "grok-test", turn: turnA, caughtUp: true, totalTokens: 0),
                                       .init(id: second, cwd: "/b", title: "B", model: "grok-test", turn: turnB, caughtUp: true, totalTokens: 0)],
            usage: .init(days: [], complete: true, sessionCount: 2, updatedAt: now), liveIDs: [first, second], registeredIDs: [first, second]))
        func ask(_ session: String, _ turn: String, _ id: Int) -> GrokQuestionRequest {
            GrokQuestionRequest.decode(["id": id, "method": "_x.ai/ask_user_question", "params": [
                "sessionId": session, "toolCallId": "ask-\(id)", "questions": [["question": "继续？", "options": [["label": "是"], ["label": "否"]]]]]],
                epoch: UUID(), turnID: turn)!
        }
        let socketA = leaders.appendingPathComponent("leader-onenative-AAAA-1.sock").path
        let socketB = leaders.appendingPathComponent("leader-onenative-BBBB-2.sock").path
        let askA = ask(first, "turn-a", 1), askB = ask(second, "turn-b", 2)
        multi.consumeShared(.init(revision: 1, connected: true, requests: [askA], status: "共享问答已连接"), from: socketA)
        multi.consumeShared(.init(revision: 1, connected: true, requests: [askB], status: "共享问答已连接"), from: socketB)
        expect(Set(multi.questions.map(\.id)) == [askA.id, askB.id] && multi.rows.filter { $0.phase == .waitingApproval }.count == 2,
               "questions from two terminal leaders are both shown")
        let routed = await multi.answer(askB, selections: ["继续？": ["是"]], texts: [:])
        expect(routed != "问题已失效，请在 Grok 原终端查看", "an answer is routed to the leader that asked")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: socketA))
        multi.consume(.init(sessions: [.init(id: second, cwd: "/b", title: "B", model: "grok-test", turn: turnB, caughtUp: true, totalTokens: 0)],
            usage: .init(days: [], complete: true, sessionCount: 1, updatedAt: now), liveIDs: [second], registeredIDs: [second]))
        expect(multi.questions.map(\.id) == [askB.id], "a vanished leader socket drops its questions")
        multi.consumeShared(.init(revision: 9, connected: true, requests: [askA]), from: socketA)
        expect(multi.questions.map(\.id) == [askB.id], "a removed leader's late callback cannot bring its question back")
        multi.configure(enabled: false)

        if CommandLine.arguments.contains("--render-interactions") {
            _ = NSApplication.shared
            let qDraft = IslandAnswerDraft(); qDraft.toggle("性能优先", for: "选择实现方式？", orderedOptions: ["性能优先", "兼容优先"])
            var q = IslandApprovalContent(id: "render-question", provider: "Grok CLI", title: "需要回答", summary: "")
            q.questions = [.init(id: "选择实现方式？", title: "选择实现方式？", options: ["性能优先", "兼容优先"], allowsText: true, multiSelect: true,
                descriptions: ["性能优先": "减少常驻开销", "兼容优先": "保留现有使用方式"])]
            q.draft = qDraft; q.submitDraft = { _, _ in "fixture" }
            var text = IslandApprovalContent(id: "render-text", provider: "Grok CLI", title: "需要回答", summary: "")
            text.questions = [.init(id: "补充要求", title: "请补充你的要求", options: [], allowsText: true)]
            let textDraft = IslandAnswerDraft(); textDraft.type("保留当前终端，先验证问答和批准。", for: "补充要求"); text.draft = textDraft; text.submitDraft = { _, _ in "fixture" }
            var p = IslandApprovalContent(id: "render-permission", provider: "Grok CLI", title: "请求使用工具", summary: "运行测试\n{\"command\":\"swift test\"}", command: true)
            p.actions = [.init(id: "once", title: "允许一次"), .init(id: "deny", title: "拒绝", destructive: true)]
            p.submitDraft = { _, _ in "fixture" }
            for (name, content) in [("question", q), ("text", text), ("permission", p)] {
                let host = NSHostingView(rootView: ActivityIslandApprovalCard(content: content).padding(16)
                    .foregroundStyle(FloatingSurfaceTheme.primary()).background(Color.black).environment(\.colorScheme, .dark))
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 340); host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 700_000_000); host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("grok-" + name + ".png"))
                }
            }
        }
        if CommandLine.arguments.contains("--live") {
            defaults.set(true, forKey: "grok.enabled")
            let live = GrokRuntime(defaults: defaults)
            live.refreshQuota()
            let deadline = Date().addingTimeInterval(25)
            while live.refreshing && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            expect(live.quota != nil && !live.quotaFailed, "production runtime queries real official quota")
            live.consume(scan(turn))
            _ = NSApplication.shared
            let host = NSHostingView(rootView: GrokView(runtime: live))
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("grok-center.png"))
            }
            let glance = NSHostingView(rootView: GrokGlanceContent(runtime: live, now: Date(), showQuota: true, showCost: true,
                showActivity: true, showDaily: true, showMonth: true, metric: .constant("cost")).padding(16)
                .foregroundStyle(FloatingSurfaceTheme.primary()).background(Color.black).environment(\.colorScheme, .dark))
            glance.frame = NSRect(x: 0, y: 0, width: 360, height: 590); glance.layoutSubtreeIfNeeded()
            if let bitmap = glance.bitmapImageRepForCachingDisplay(in: glance.bounds) {
                glance.cacheDisplay(in: glance.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("grok-glance.png"))
            }
            print("LIVE Grok quota: \(live.quota!.remainingPercent)% remaining; no session or model prompt sent")
            live.stop()
        }
        print("PASS Grok runtime: \(checks) checks")
    }
}
