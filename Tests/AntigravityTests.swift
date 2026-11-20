import Darwin
import Foundation
import SQLite3

@main
enum AntigravityCoreTests {
    static func main() async throws {
        let helperPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        precondition(!helperPath.isEmpty && FileManager.default.isExecutableFile(atPath: helperPath), "helper binary required")

        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), "FAIL: \(message)")
            checks += 1
        }

        // 1. Model formatting & official pricing + strict unpriced boundary
        let carbon = AntigravityPricing.formatModel("gemini-4-carbon-medium")
        expect(carbon.model == "Gemini 4 Carbon" && carbon.effort == "Medium", "Gemini 4 Carbon model and effort parsed")
        let novDate = Date(timeIntervalSince1970: 1_795_100_000) // 2026-11-19 UTC (promotional rate $2 / $0.10 / $10)
        let decDate = Date(timeIntervalSince1970: 1_796_200_000) // 2026-12-02 UTC (standard rate $4 / $0.20 / $20)
        let carbonNovCost = AntigravityPricing.estimateCost(model: "gemini-4-carbon-medium", inputTokens: 1_000_000, cacheReadTokens: 1_000_000, outputTokens: 100_000, at: novDate)
        expect(carbonNovCost != nil && abs(carbonNovCost! - (2.0 + 0.10 + 1.0)) < 0.0001, "Gemini 4 Carbon Nov 2026 official rate")
        let carbonDecCost = AntigravityPricing.estimateCost(model: "gemini-4-carbon-medium", inputTokens: 1_000_000, cacheReadTokens: 1_000_000, outputTokens: 100_000, at: decDate)
        expect(carbonDecCost != nil && abs(carbonDecCost! - (4.0 + 0.20 + 2.0)) < 0.0001, "Gemini 4 Carbon Dec 2026 scheduled official rate")

        let neonDisplay = AntigravityPricing.formatModel("Gemini 4 Neon (High)")
        expect(neonDisplay.model == "Gemini 4 Neon" && neonDisplay.effort == "High", "display-label model and effort normalized")
        let neonCost = AntigravityPricing.estimateCost(model: "Gemini 4 Neon (High)", inputTokens: 1_000_000, cacheReadTokens: 1_000_000, outputTokens: 100_000, at: novDate)
        expect(neonCost != nil && abs(neonCost! - (3.0 + 0.15 + 1.5)) < 0.0001, "Gemini 4 Neon official rate from display label")

        let flash = AntigravityPricing.formatModel("gemini-3.8-flash-high")
        expect(flash.model == "Gemini 3.8 Flash" && flash.effort == "High", "versioned flash model parsed")
        let flashCost = AntigravityPricing.estimateCost(model: "gemini-3.8-flash-high", inputTokens: 1_000_000, cacheReadTokens: 1_000_000, outputTokens: 100_000, at: novDate)
        expect(flashCost != nil && abs(flashCost! - (0.75 + 0.075 + 0.375)) < 0.0001, "Gemini 3.8 Flash official rate")

        expect(AntigravityPricing.estimateCost(model: "gemini-internal-prototype-x", inputTokens: 10_000, cacheReadTokens: 5_000, outputTokens: 1_000) == nil,
               "genuinely unpublished internal model remains unpriced")

        let sonnet = AntigravityPricing.formatModel("claude-sonnet-5-5-high")
        expect(sonnet.model == "Claude Sonnet 5.5" && sonnet.effort == "High", "partner Claude model parsed")
        let sonnetCost = AntigravityPricing.estimateCost(model: "claude-sonnet-5-5-high", inputTokens: 1_000_000, cacheReadTokens: 1_000_000, outputTokens: 100_000)
        expect(sonnetCost != nil && abs(sonnetCost! - (2.0 + 0.1 + 1.0)) < 0.0001, "Claude Sonnet 5.5 official rate aligned with ClaudeCodePricing")

        let proCost = AntigravityPricing.estimateCost(model: "gemini-2.5-pro", inputTokens: 100_000, cacheReadTokens: 50_000, outputTokens: 10_000)
        expect(proCost != nil && abs(proCost! - (0.125 + 0.00625 + 0.10)) < 0.0001, "Gemini 2.5 Pro <=200k rate")
        let proHighTier = AntigravityPricing.estimateCost(model: "gemini-2.5-pro", inputTokens: 150_000, cacheReadTokens: 100_000, outputTokens: 10_000)
        expect(proHighTier != nil && abs(proHighTier! - (0.375 + 0.025 + 0.15)) < 0.0001, "Gemini 2.5 Pro >200k tier rate")

        // 2. Plan & Quota decoding + freshness/expiration boundaries
        expect(AntigravityPlanDisplayName.resolve("Pro") == "Google AI Pro", "Pro tier normalized")
        expect(AntigravityPlanDisplayName.resolve("ultra_20x") == "Google AI Ultra 20x", "Ultra 20x tier normalized")

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let futureISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(7_200))
        let pastISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let quotaPayload: [String: Any] = [
            "capturedAt": now.timeIntervalSince1970,
            "plan_tier": "Pro",
            "credits": 42,
            "useG1Credits": true,
            "quota": [
                "gemini-5h": ["remaining_fraction": 0.64, "reset_time": futureISO],
                "gemini-weekly": ["remaining_fraction": 0.912, "reset_in_seconds": 300_000],
                "claude-weekly": ["remaining_fraction": 0.25, "reset_time": pastISO]
            ]
        ]
        let decodedQuota = AntigravityQuotaSnapshot.decode(object: quotaPayload)
        expect(decodedQuota != nil, "quota decoded")
        expect(decodedQuota?.resolvedPlan == "Google AI Pro", "decoded plan")
        expect(decodedQuota?.aiCredits == 42 && decodedQuota?.useG1Credits == true, "credits and strict bool decoded")
        let activeAtNow = decodedQuota?.activeWindows(at: now) ?? []
        expect(activeAtNow.count == 2, "expired partner window excluded")
        expect(activeAtNow.first?.id == "gemini-5h" && activeAtNow.first?.remainingPercent == 64, "5h window prioritized")
        expect(activeAtNow.last?.id == "gemini-weekly" && activeAtNow.last?.remainingPercent == 91, "weekly window preserved")

        let stringBoolPayload: [String: Any] = [
            "capturedAt": now.timeIntervalSince1970,
            "plan_tier": "Free",
            "useG1Credits": 1
        ]
        expect(AntigravityQuotaSnapshot.decode(object: stringBoolPayload)?.useG1Credits == nil, "numeric 1 rejected for useG1Credits bool")
        expect(AntigravityQuotaSnapshot.decode(object: [
            "capturedAt": now.addingTimeInterval(65).timeIntervalSince1970,
            "quota": ["gemini-weekly": ["remaining_fraction": 0.5, "reset_time": futureISO]]
        ])?.activeWindows(at: now).isEmpty == true, "future-skewed capture hidden")

        // 3. Isolated multi-surface scanner, SQLite summaries, subagent filtering & flock liveness
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ag-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let geminiDir = tempRoot.appendingPathComponent(".gemini", isDirectory: true)
        let cliRoot = geminiDir.appendingPathComponent("antigravity-cli", isDirectory: true)
        let appRoot = geminiDir.appendingPathComponent("antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: cliRoot.appendingPathComponent("presence"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appRoot.appendingPathComponent("presence"), withIntermediateDirectories: true)

        try createSummaryDB(at: cliRoot.appendingPathComponent("conversation_summaries.db"), rows: [
            ("conv-root", " CLI Root Task ", "[\"file:///Users/dev/My%20Project\"]", "CASCADE_RUN_STATUS_RUNNING", 0, "", 1, 0),
            ("conv-sub", "Subagent Research", "[\"file:///Users/dev/My%20Project\"]", "CASCADE_RUN_STATUS_RUNNING", 1, "conv-root", 1, 0)
        ])
        try createSummaryDB(at: appRoot.appendingPathComponent("conversation_summaries.db"), rows: [
            ("conv-app", "Desktop Task", "[\"file:///Users/dev/AppRepo\"]", "CASCADE_RUN_STATUS_IDLE", 0, "", 0, 0)
        ])

        let rootTranscript = cliRoot.appendingPathComponent("brain/conv-root/.system_generated/logs/transcript.jsonl")
        let subTranscript = cliRoot.appendingPathComponent("brain/conv-sub/.system_generated/logs/transcript.jsonl")
        let appTranscript = appRoot.appendingPathComponent("brain/conv-app/.system_generated/logs/transcript.jsonl")
        for url in [rootTranscript, subTranscript, appTranscript] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let stepTime = "2026-11-19T12:00:00Z"
        // Root CLI session has uncached in=1000, cache=2000, out=500 -> 3500 tokens (unpriced gemini-4-carbon-medium), waiting on ask_question + trailing partial line
        let rootLines = [
            "{\"step_index\":0,\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"content\":\"<USER_REQUEST>\\nBuild feature\\n</USER_REQUEST>\"}",
            "{\"step_index\":1,\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"model\":\"gemini-4-carbon-medium\",\"input_tokens\":1000,\"cache_read_tokens\":2000,\"output_tokens\":500,\"thinking\":\"secret thought\",\"tool_calls\":[{\"name\":\"ask_question\",\"args\":{\"questions\":[]}}]}"
        ].joined(separator: "\n") + "\n{\"step_index\":2,\"partial\":"
        try Data(rootLines.utf8).write(to: rootTranscript)

        // Subagent session has unpriced internal prototype tokens: in=1000, cache=0, out=200 -> 1200 tokens
        let subLines = [
            "{\"step_index\":0,\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"content\":\"sub\"}",
            "{\"step_index\":1,\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"model\":\"gemini-internal-prototype-x\",\"input_tokens\":1000,\"cache_read_tokens\":0,\"output_tokens\":200,\"content\":\"done\"}"
        ].joined(separator: "\n") + "\n"
        try Data(subLines.utf8).write(to: subTranscript)

        // App session has anonymous transcript step (model omitted) + CLI statusLine usage hint Test
        let appLines = [
            "{\"step_index\":0,\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"content\":\"check app\"}",
            "{\"step_index\":1,\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"model\":\"claude-sonnet-5-5-medium\",\"input_tokens\":500,\"cache_read_tokens\":500,\"output_tokens\":100,\"content\":\"All good\"}"
        ].joined(separator: "\n") + "\n"
        try Data(appLines.utf8).write(to: appTranscript)

        let anonCLITranscript = cliRoot.appendingPathComponent("brain/conv-anon/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(at: anonCLITranscript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let anonLines = [
            "{\"step_index\":0,\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"content\":\"anon cli\"}",
            "{\"step_index\":1,\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"input_tokens\":10000,\"cache_read_tokens\":0,\"output_tokens\":1000,\"content\":\"Resolved via usage hint\"}"
        ].joined(separator: "\n") + "\n"
        try Data(anonLines.utf8).write(to: anonCLITranscript)

        let statusCacheDir = tempRoot.appendingPathComponent("agy-statusline", isDirectory: true)
        try FileManager.default.createDirectory(at: statusCacheDir.appendingPathComponent("usage"), withIntermediateDirectories: true)
        let anonUsageHint: [String: Any] = [
            "version": 1,
            "storage_root": cliRoot.standardizedFileURL.path,
            "conversation_id": "conv-anon",
            "model": "Gemini 4 Neon (High)",
            "total_tokens": 11_000
        ]
        try JSONSerialization.data(withJSONObject: anonUsageHint).write(to: statusCacheDir.appendingPathComponent("usage/conv-anon.json"))

        // Test real flock detection on presence lock
        let rootLockURL = cliRoot.appendingPathComponent("presence/conv-root.lock")
        FileManager.default.createFile(atPath: rootLockURL.path, contents: Data())
        expect(!AntigravityScanner.isExclusivelyLocked(rootLockURL), "unlocked presence file reports false")
        let lockFD = Darwin.open(rootLockURL.path, O_RDWR | O_CLOEXEC)
        precondition(lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0, "acquire exclusive lock")
        defer {
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
        }
        expect(AntigravityScanner.isExclusivelyLocked(rootLockURL), "held flock reports exclusively locked")

        let scanner = AntigravityScanner(geminiDirectory: geminiDir, statusLineCacheDirectory: statusCacheDir)
        let firstScan = await scanner.scan(now: now)
        // Total tokens across CLI root (3500) + CLI subagent (1200) + CLI anon (11000) + App root (1100) = 16800
        expect(firstScan.usage.lifetimeTokens == 16_800, "all surface and subagent tokens counted once: got \(firstScan.usage.lifetimeTokens)")
        expect(firstScan.usage.sessionCount == 4, "four transcripts counted")
        expect(!firstScan.usage.complete, "partial trailing line marks scan incomplete without crashing")
        expect(firstScan.usage.unpricedModels == ["gemini-internal-prototype-x"], "only genuinely unpriced model recorded; carbon & hinted neon priced")
        let mixedDay = firstScan.usage.days.first
        expect(mixedDay != nil && mixedDay!.hasUnpriced && (mixedDay!.cost ?? 0) > 0.05,
               "mixed day preserves known priced lower bound rather than dropping bar to nil")
        expect(firstScan.sessions.count == 3 && !firstScan.sessions.contains(where: { $0.id == "conv-sub" }),
               "subagent excluded from live session rows")

        let rootSession = firstScan.sessions.first { $0.id == "conv-root" }
        expect(rootSession?.cwd == "/Users/dev/My Project", "percent-encoded workspace URI decoded")
        expect(rootSession?.isLockedLive == true, "flock live state surfaced")
        expect(rootSession?.turn.phase == .waitingQuestion, "unresolved ask_question enters waitingQuestion")

        // Complete the trailing line + finish turn, including >70KB multi-chunk boundary lines, verify incremental read catches up without double-counting!
        let padding = String(repeating: "x", count: 70_000)
        let completedTail = [
            "{\"step_index\":0,\"type\":\"USER_INPUT\",\"source\":\"USER_EXPLICIT\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"content\":\"<USER_REQUEST>\\nBuild feature\\n</USER_REQUEST>\"}",
            "{\"step_index\":1,\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"model\":\"gemini-4-carbon-medium\",\"input_tokens\":1000,\"cache_read_tokens\":2000,\"output_tokens\":500,\"tool_calls\":[{\"name\":\"ask_question\",\"args\":{\"questions\":[]}}]}",
            "{\"step_index\":2,\"type\":\"GENERIC\",\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"content\":\"\(padding)\"}",
            "{\"step_index\":3,\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(stepTime)\",\"model\":\"gemini-4-carbon-medium\",\"input_tokens\":200,\"cache_read_tokens\":3000,\"output_tokens\":100,\"content\":\"Feature built!\"}"
        ].joined(separator: "\n") + "\n"
        try Data(completedTail.utf8).write(to: rootTranscript, options: .atomic) // inode replacement!
        let secondScan = await scanner.scan(now: now)
        expect(secondScan.usage.complete, "atomic rewrite caught up cleanly")
        expect(secondScan.usage.lifetimeTokens == 16_800 + 3_300, "inode replacement recounted cleanly without doubling")
        expect(secondScan.sessions.first { $0.id == "conv-root" }?.turn.phase == .completed, "turn transitioned to completed")

        // 4. Installer round-trip, backup preservation, NO PreToolUse, statusLine forwarding & email stripping
        let configDir = geminiDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let initialHooks: [String: Any] = [
            "user-linter": [
                "enabled": true,
                "PostToolUse": [["matcher": "edit_file", "hooks": [["command": "echo lint"]]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: initialHooks, options: [.prettyPrinted])
            .write(to: configDir.appendingPathComponent("hooks.json"))

        let forwardScript = tempRoot.appendingPathComponent("orig-status.sh")
        try Data("#!/bin/sh\ncat >/dev/null\nprintf 'USER_STATUS_OK'\n".utf8).write(to: forwardScript)
        chmod(forwardScript.path, S_IRWXU)

        let initialCLISettings: [String: Any] = [
            "useG1Credits": true,
            "statusLine": [
                "enabled": true,
                "type": "command",
                "command": forwardScript.path
            ]
        ]
        let cliSettingsURL = cliRoot.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: initialCLISettings, options: [.prettyPrinted]).write(to: cliSettingsURL)
        chmod(cliSettingsURL.path, S_IRUSR | S_IWUSR)

        let supportDir = tempRoot.appendingPathComponent("support", isDirectory: true)
        let socketURL = URL(fileURLWithPath: "/tmp/ag-pulse-\(UUID().uuidString.prefix(8)).sock")
        defer { unlink(socketURL.path); unlink(socketURL.path + ".lock") }
        let token = "secret-test-token-12345"
        let installer = AntigravityInstaller(
            socketURL: socketURL,
            authenticationToken: token,
            geminiDirectory: geminiDir,
            supportDirectory: supportDir,
            helperURL: URL(fileURLWithPath: helperPath)
        )

        final class MessageBox: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [ClaudeCodeBridgeMessage] = []
            func append(_ message: ClaudeCodeBridgeMessage) { lock.withLock { items.append(message) } }
            func snapshot() -> [ClaudeCodeBridgeMessage] { lock.withLock { items } }
        }
        let messageBox = MessageBox()
        let bridge = ClaudeCodeBridge(socketURL: socketURL, authenticationToken: token)
        try bridge.start(onMessage: { msg in
            messageBox.append(msg)
        }, onDisconnect: { _ in })
        defer { bridge.stop() }

        try installer.install(.init(hooks: true, statusLine: true))
        let installedState = installer.state()
        expect(installedState.hooksInstalled && installedState.statusLineInstalled, "both hooks and statusLine installed")
        expect(FileManager.default.fileExists(atPath: installer.hooksURL.appendingPathExtension("codex-pulse-backup").path), "hooks backup created")
        expect(FileManager.default.fileExists(atPath: installer.cliSettingsURL.appendingPathExtension("codex-pulse-backup").path), "CLI settings backup created")

        var modeStat = stat()
        expect(lstat(cliSettingsURL.path, &modeStat) == 0 && (modeStat.st_mode & 0o777) == 0o600, "0600 mode on settings.json preserved")

        let hooksAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.hooksURL)) as? [String: Any]
        expect(hooksAfter?["user-linter"] != nil, "user's own hook preserved")
        let pulseHook = hooksAfter?["codex-pulse"] as? [String: Any]
        expect(pulseHook != nil && pulseHook?["PreToolUse"] == nil, "PreToolUse is NEVER registered")

        let parsedSQLiteTime = AntigravityScanner.parseSQLiteTimestamp("2026-11-19 19:05:31.541368+00:00")
        expect(parsedSQLiteTime != nil, "SQLite space-separated timestamp with microseconds parsed")
        expect(AntigravityScanner.parseSQLiteTimestamp("0001-01-01 00:00:00+00:00") == nil, "zero sentinel SQLite timestamp ignored")

        // Invoke helper in statusLine mode -> must forward USER_STATUS_OK, strip email, save snapshot & notify bridge
        let statusInput = try JSONSerialization.data(withJSONObject: [
            "session_id": "conv-root",
            "cwd": "/Users/dev/My Project",
            "agent_state": "working",
            "plan_tier": "Pro",
            "email": "sensitive-user@example.com",
            "secretToken": "MUST_NOT_LEAK",
            "credits": 88,
            "quota": ["gemini-weekly": ["remaining_fraction": 0.77, "reset_time": futureISO]]
        ])
        let statusOut = try runProcess(
            executable: installer.installedHelperURL.path,
            arguments: ["--antigravity-statusline", "--configuration", installer.routeURL.path],
            stdinData: statusInput
        )
        expect(String(decoding: statusOut, as: UTF8.self) == "USER_STATUS_OK", "original statusLine output forwarded")
        let savedSnapshotRaw = try String(contentsOf: installer.statusLineSnapshotURL, encoding: .utf8)
        expect(!savedSnapshotRaw.contains("sensitive-user@example.com") && !savedSnapshotRaw.contains("MUST_NOT_LEAK"),
               "email and unknown secrets stripped from statusLine snapshot")
        expect(AntigravityQuotaSnapshot.decode(snapshot: Data(savedSnapshotRaw.utf8))?.aiCredits == 88, "saved snapshot decodes quota & credits")

        // Invoke helper in hook mode (`PostToolUse` & `Stop`), including fail-closed broken route check!
        let hookInput = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "PostToolUse",
            "conversationId": "conv-root",
            "cwd": "/Users/dev/My Project",
            "toolCall": ["id": "t1", "name": "run_command", "args": ["CommandLine": "secret --key 123", "toolSummary": "Run unit tests"]]
        ])
        let postOut = try runProcess(
            executable: installer.installedHelperURL.path,
            arguments: ["--antigravity-hook", "--configuration", installer.routeURL.path],
            stdinData: hookInput
        )
        expect(String(decoding: postOut, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "{}",
               "PostToolUse returns valid empty JSON")

        let brokenStopOut = try runProcess(
            executable: installer.installedHelperURL.path,
            arguments: ["--antigravity-hook", "--configuration", "/nonexistent/route.json"],
            stdinData: Data("{\"hookEventName\":\"Stop\",\"conversationId\":\"conv-root\"}".utf8)
        )
        let brokenStopObj = try JSONSerialization.jsonObject(with: brokenStopOut) as? [String: Any]
        expect(brokenStopObj?["decision"] as? String == "stop", "broken route on Stop still fails safe with decision:stop")

        let captured = messageBox.snapshot()
        expect(captured.contains { $0.kind == "statusLine" } && captured.contains { $0.kind == "hook" }, "bridge received both statusLine and hook payloads")
        for item in captured where item.kind == "hook" {
            let text = String(decoding: item.payload, as: UTF8.self)
            expect(!text.contains("secret --key 123") && text.contains("Run unit tests"), "raw CommandLine stripped while toolSummary preserved")
        }

        // Clean uninstall restores exact user hooks and original statusLine
        try installer.uninstall()
        let restoredHooks = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.hooksURL)) as? [String: Any]
        expect(restoredHooks?["codex-pulse"] == nil && restoredHooks?["user-linter"] != nil, "uninstall removes only codex-pulse hook")
        let restoredCLI = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.cliSettingsURL)) as? [String: Any]
        expect((restoredCLI?["statusLine"] as? [String: Any])?["command"] as? String == forwardScript.path, "original statusLine restored")
        expect(restoredCLI?["useG1Credits"] as? Bool == true, "unrelated CLI settings preserved")

        print("Antigravity core: \(checks)/\(checks) passed")
    }

    private static func createSummaryDB(
        at url: URL,
        rows: [(String, String, String, String, Int, String, Int, Int)]
    ) throws {
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK, "open sqlite")
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE conversation_summaries (
            conversation_id text PRIMARY KEY,
            title text NOT NULL DEFAULT "",
            preview text NOT NULL DEFAULT "",
            step_count integer NOT NULL DEFAULT 0,
            last_modified_time datetime NOT NULL DEFAULT "2026-11-19T12:00:00Z",
            workspace_uris text NOT NULL DEFAULT "[]",
            status text NOT NULL DEFAULT "",
            source text NOT NULL DEFAULT "",
            project_id text NOT NULL DEFAULT "",
            agent_name text NOT NULL DEFAULT "",
            parent_conversation_id text NOT NULL DEFAULT "",
            nesting_depth integer NOT NULL DEFAULT 0,
            not_fully_idle numeric NOT NULL DEFAULT 0,
            killed numeric NOT NULL DEFAULT 0,
            last_user_input_time datetime NOT NULL DEFAULT "2026-11-19T12:00:00Z"
        );
        """
        precondition(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "create schema")
        for row in rows {
            var stmt: OpaquePointer?
            let insert = "INSERT INTO conversation_summaries (conversation_id, title, workspace_uris, status, nesting_depth, parent_conversation_id, not_fully_idle, killed) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
            precondition(sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK, "prepare insert")
            sqlite3_bind_text(stmt, 1, (row.0 as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (row.1 as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (row.2 as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (row.3 as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 5, Int32(row.4))
            sqlite3_bind_text(stmt, 6, (row.5 as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 7, Int32(row.6))
            sqlite3_bind_int(stmt, 8, Int32(row.7))
            precondition(sqlite3_step(stmt) == SQLITE_DONE, "step insert")
            sqlite3_finalize(stmt)
        }
    }

    private static func runProcess(executable: String, arguments: [String], stdinData: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        inPipe.fileHandleForWriting.write(stdinData)
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "helper exited nonzero")
        return out
    }
}
