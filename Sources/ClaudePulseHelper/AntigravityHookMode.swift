import Darwin
import Foundation

/// Antigravity entry points of the shared activity helper.
///
/// `--antigravity-hook --configuration <route.json>` forwards bounded lifecycle
/// metadata (`SessionStart`, `PreInvocation`, `PostInvocation`, `PreToolUse`, `PostToolUse`, `Stop`)
/// over Agent Pulse's private Unix socket. Antigravity hooks are synchronous and
/// fail-safe:
/// - `Stop` always falls back to `{"decision":"stop"}`
/// - `PreToolUse` always falls back to `{"decision":"allow"}` (which delegates to
///   Antigravity's native permission policy without auto-approving; only an explicit
///   user click in Agent Pulse emits `"auto_approve"` or `"deny"`).
///
/// `--antigravity-statusline --configuration <route.json>` records allowlisted
/// quota/model/state telemetry (explicitly excluding `email` and credentials) and
/// forwards stdin to the user's original statusline command when configured.
enum AntigravityHookMode {
    static func handles(_ arguments: [String]) -> Bool {
        guard let mode = arguments.first,
              mode == "--antigravity-hook" || mode == "--antigravity-statusline" else { return false }
        if let event = ProcessInfo.processInfo.environment["GROK_HOOK_EVENT"], !event.isEmpty {
            if mode == "--antigravity-hook" { ClaudeCodeHookIO.writeStandardOutput(Data("{}".utf8)) }
            return true
        }
        if mode == "--antigravity-hook" {
            AntigravityHookForwarder.run(arguments: arguments)
        } else {
            AntigravityStatusLineForwarder.run(arguments: arguments)
        }
        return true
    }
}

enum AntigravityLocalPolicyGate {
    private static let fileTools: Set<String> = [
        "read_file", "view_file",
        "write_file", "write_to_file",
        "edit_file", "replace_file_content", "multi_replace_file_content"
    ]
    private static let writeTools: Set<String> = [
        "write_file", "write_to_file",
        "edit_file", "replace_file_content", "multi_replace_file_content"
    ]

    static func shouldPromptInIsland(
        toolName: String,
        args: [String: Any],
        transcriptPath: String,
        cwd: String,
        workspacePaths: [String],
        parentConversationID: String?,
        geminiDirectoryPath: String?
    ) -> Bool {
        // Subagents are managed under their parent session; let native sandbox/policy govern them.
        if let parent = parentConversationID, !parent.isEmpty {
            return false
        }
        if toolName == "ask_question" {
            if let list = args["questions"] as? [Any], !list.isEmpty {
                return true
            }
            return false
        }

        let geminiRoot = resolveGeminiRoot(explicit: geminiDirectoryPath)
        let roots = normalizedWorkspaceRoots(workspacePaths: workspacePaths, cwd: cwd, geminiRoot: geminiRoot)
        let isCLI = transcriptPath.contains("/antigravity-cli/")

        if isCLI {
            let cliPolicy = readCLIPolicy(geminiRoot: geminiRoot)
            if cliPolicy.toolPermission == "always-proceed" {
                return false
            }
            if fileTools.contains(toolName) {
                let targetPath = extractFilePath(from: args, cwd: cwd)
                if let targetPath, !isInsideAllowedRoots(path: targetPath, roots: roots), !cliPolicy.allowNonWorkspaceAccess {
                    return true
                }
                if writeTools.contains(toolName) {
                    if cliPolicy.toolPermission == "strict" { return true }
                    if cliPolicy.agentMode.isEmpty && cliPolicy.toolPermission == "request-review" { return true }
                }
                return false
            }
            if toolName == "run_command" {
                let cmd = (args["CommandLine"] as? String) ?? ""
                if matchesCLIAllowRule(command: cmd, allowRules: cliPolicy.allowRules) {
                    return false
                }
                if cliPolicy.toolPermission == "strict" { return true }
                if cliPolicy.agentMode != "auto" && cliPolicy.toolPermission == "request-review" {
                    return true
                }
                return isSensitiveCommand(cmd, cwd: (args["Cwd"] as? String) ?? cwd, roots: roots)
            }
            if toolName == "read_url_content" || toolName.hasPrefix("mcp__") {
                return cliPolicy.toolPermission == "strict" || cliPolicy.toolPermission == "request-review"
            }
            return false
        } else {
            let appPolicy = readAppPolicy(geminiRoot: geminiRoot)
            if appPolicy.preset == "AGENT_PERMISSION_PRESET_TURBO" || appPolicy.autoExecution == "ALWAYS_PROCEED" {
                return false
            }
            if fileTools.contains(toolName) {
                if let targetPath = extractFilePath(from: args, cwd: cwd),
                   !isInsideAllowedRoots(path: targetPath, roots: roots),
                   appPolicy.nonWorkspacePolicy != "ALLOW" {
                    return true
                }
                return false
            }
            if toolName == "read_url_content" || toolName.hasPrefix("mcp__") {
                return true
            }
            if toolName == "run_command" {
                let cmd = (args["CommandLine"] as? String) ?? ""
                if appPolicy.preset == "AGENT_PERMISSION_PRESET_REQUEST_REVIEW" || appPolicy.autoExecution == "REQUIRE_REVIEW" {
                    return true
                }
                return isSensitiveCommand(cmd, cwd: (args["Cwd"] as? String) ?? cwd, roots: roots)
            }
            return false
        }
    }

    private struct CLIPolicy {
        var agentMode: String = "auto"
        var toolPermission: String = "request-review"
        var allowNonWorkspaceAccess: Bool = false
        var allowRules: [String] = []
    }

    private struct AppPolicy {
        var preset: String = "AGENT_PERMISSION_PRESET_DEFAULT"
        var autoExecution: String = ""
        var nonWorkspacePolicy: String = "ASK"
    }

    private static func resolveGeminiRoot(explicit: String?) -> String {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: explicit).standardizedFileURL.path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func readCLIPolicy(geminiRoot: String) -> CLIPolicy {
        var policy = CLIPolicy()
        let path = (geminiRoot as NSString).appendingPathComponent("antigravity-cli/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count <= 1_048_576,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return policy
        }
        if let mode = root["agentMode"] as? String { policy.agentMode = mode }
        if let perm = root["toolPermission"] as? String, !perm.isEmpty { policy.toolPermission = perm }
        if let nonWs = root["allowNonWorkspaceAccess"] as? Bool { policy.allowNonWorkspaceAccess = nonWs }
        if let perms = root["permissions"] as? [String: Any],
           let allow = perms["allow"] as? [String] {
            policy.allowRules = allow
        }
        return policy
    }

    private static func readAppPolicy(geminiRoot: String) -> AppPolicy {
        var policy = AppPolicy()
        let path = (geminiRoot as NSString).appendingPathComponent("config/config.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count <= 1_048_576,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let settings = root["userSettings"] as? [String: Any] else {
            return policy
        }
        if let preset = settings["permissionPreset"] as? String, !preset.isEmpty {
            policy.preset = preset
        }
        if let autoExec = settings["autoExecutionPolicy"] as? String {
            policy.autoExecution = autoExec
        }
        if let nonWs = settings["nonWorkspaceFileAccessPolicy"] as? String, !nonWs.isEmpty {
            policy.nonWorkspacePolicy = nonWs
        }
        return policy
    }

    private static func normalizedWorkspaceRoots(workspacePaths: [String], cwd: String, geminiRoot: String) -> [String] {
        var list: [String] = [geminiRoot, "/tmp", "/private/tmp", NSTemporaryDirectory()]
        for raw in workspacePaths where !raw.isEmpty {
            list.append(URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        if !cwd.isEmpty {
            list.append(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        return list
    }

    private static func extractFilePath(from args: [String: Any], cwd: String) -> String? {
        guard let raw = (args["Path"] as? String)
            ?? (args["TargetFile"] as? String)
            ?? (args["AbsolutePath"] as? String),
              !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if !cwd.isEmpty {
            url = URL(fileURLWithPath: cwd).appendingPathComponent(expanded)
        } else {
            return nil
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isInsideAllowedRoots(path: String, roots: [String]) -> Bool {
        for root in roots where !root.isEmpty {
            let cleanRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
            if path == cleanRoot || path.hasPrefix(cleanRoot + "/") {
                return true
            }
        }
        return false
    }

    private static func matchesCLIAllowRule(command: String, allowRules: [String]) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        for rule in allowRules {
            if rule == "command(*)" { return true }
            if rule.hasPrefix("command(") && rule.hasSuffix(")") {
                let inner = String(rule.dropFirst(8).dropLast())
                if !inner.hasPrefix("regex:"),
                   !trimmed.contains("$("), !trimmed.contains("`"),
                   (trimmed == inner || trimmed.hasPrefix(inner + " ")) {
                    return true
                }
            }
        }
        return false
    }

    private static func isSensitiveCommand(_ command: String, cwd: String, roots: [String]) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if !cwd.isEmpty {
            let resolvedCwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
            if !isInsideAllowedRoots(path: resolvedCwd, roots: roots) {
                return true
            }
        }
        let patterns = [
            #"(^|[;&|]\s*)sudo\b"#,
            #"\brm\s+-[a-zA-Z]*[rRfF][a-zA-Z]*\b"#,
            #"\bgit\s+(push|reset\s+--hard|clean\s+-[a-zA-Z]*f)\b"#,
            #"\bgh\s+(release|pr\s+merge|repo\s+delete|repo\s+rename)\b"#,
            #"\b(curl|wget|ssh|scp|rsync|sftp|nc|ncat)\b"#,
            #"\b(brew|npm|pnpm|yarn|pip|pip3|cargo)\s+(install|uninstall|publish|upgrade)\b"#,
            #"\b(kill|pkill|killall|launchctl|osascript|defaults\s+write|chmod\s+777|chown)\b"#
        ]
        for pattern in patterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}

enum AntigravityHookForwarder {
    static func safeResponse(for event: String) -> Data {
        if event == "Stop" {
            return Data("{\"decision\":\"stop\"}\n".utf8)
        }
        if event == "PreToolUse" {
            return Data("{\"decision\":\"allow\"}\n".utf8)
        }
        return Data("{}\n".utf8)
    }

    static func parseArguments(_ arguments: [String]) -> (routePath: String, explicitEvent: String?)? {
        guard arguments.first == "--antigravity-hook" else { return nil }
        var routePath: String?
        var explicitEvent: String?
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            switch flag {
            case "--configuration":
                guard routePath == nil, !value.isEmpty else { return nil }
                routePath = value
            case "--event":
                guard explicitEvent == nil, !value.isEmpty else { return nil }
                explicitEvent = value
            default:
                return nil
            }
            index += 2
        }
        guard let routePath else { return nil }
        return (routePath, explicitEvent)
    }

    /// Antigravity < 1.5.4 omitted `hookEventName` (and `cwd`) from hook stdin JSON.
    /// Resolve from stdin `hookEventName` -> CLI `--event` -> protojson `HookArgs` oneof shape,
    /// so `PreToolUse` never falls through to `{}` (which Antigravity treats as an empty-reason deny).
    static func resolveEventName(object: [String: Any], explicitEvent: String?) -> String {
        if let name = (object["hookEventName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if let explicit = explicitEvent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        if object["toolCall"] is [String: Any] {
            if object["result"] != nil || object["error"] != nil {
                return "PostToolUse"
            }
            return "PreToolUse"
        }
        if object["terminationReason"] != nil || object["executionNum"] != nil || object["fullyIdle"] != nil {
            return "Stop"
        }
        if object["modelOutput"] != nil || object["modelThinking"] != nil {
            return "PostInvocation"
        }
        if object["invocationNum"] != nil || object["initialNumSteps"] != nil {
            return "PreInvocation"
        }
        if let conv = object["conversationId"] as? String, !conv.isEmpty {
            return "SessionStart"
        }
        return ""
    }

    static func run(arguments: [String]) {
        signal(SIGPIPE, SIG_IGN)
        let parsedArgs = parseArguments(arguments)
        let input = ClaudeCodeHookIO.readStandardInput(maximumBytes: 1_048_576)
        let object = input.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let event = resolveEventName(object: object, explicitEvent: parsedArgs?.explicitEvent)
        var responseData = safeResponse(for: event)
        defer {
            ClaudeCodeHookIO.writeStandardOutput(responseData)
        }

        guard let parsedArgs,
              let route = ClaudeCodeRoute.read(from: parsedArgs.routePath),
              !event.isEmpty,
              let conversationID = object["conversationId"] as? String,
              !conversationID.isEmpty, conversationID.utf8.count <= 256 else {
            return
        }

        let transcriptPath = (object["transcriptPath"] as? String) ?? ""
        let workspacePaths = (object["workspacePaths"] as? [Any])?.compactMap { $0 as? String } ?? []
        let rawCwd = (object["cwd"] as? String) ?? ""
        let cwd = rawCwd.isEmpty ? (workspacePaths.first ?? "") : rawCwd
        let parentConversationID = object["parentConversationId"] as? String
        let toolCall = object["toolCall"] as? [String: Any]
        let toolName = (toolCall?["name"] as? String) ?? ""
        let toolArgs = (toolCall?["args"] as? [String: Any]) ?? [:]

        let awaitsDecision: Bool = {
            guard event == "PreToolUse", route.interactiveApprovals == true, !toolName.isEmpty else {
                return false
            }
            return AntigravityLocalPolicyGate.shouldPromptInIsland(
                toolName: toolName,
                args: toolArgs,
                transcriptPath: transcriptPath,
                cwd: cwd,
                workspacePaths: workspacePaths,
                parentConversationID: parentConversationID,
                geminiDirectoryPath: route.geminiDirectoryPath
            )
        }()

        // Non-interactive PreToolUse calls return passthrough immediately without socket round-trip overhead.
        if event == "PreToolUse" && !awaitsDecision {
            return
        }

        var payload: [String: Any] = [
            "hookEventName": String(event.prefix(64)),
            "conversationId": conversationID
        ]
        for key in ["transcriptPath", "modelName", "cwd", "terminationReason", "parentConversationId"] {
            if let text = object[key] as? String, !text.isEmpty {
                payload[key] = String(text.prefix(4_096))
            }
        }
        if !workspacePaths.isEmpty {
            payload["workspacePaths"] = workspacePaths.prefix(8).map { String($0.prefix(4_096)) }
        }
        for key in ["stepIdx", "invocationNum", "executionNum"] {
            if let number = object[key] as? NSNumber, number.doubleValue.isFinite {
                payload[key] = number.intValue
            }
        }
        for key in ["fullyIdle", "continuationActive"] {
            if let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                payload[key] = number.boolValue
            }
        }
        if let error = object["error"] as? String, !error.isEmpty {
            payload["error"] = String(error.prefix(256))
        }
        if let userText = object["lastUserInput"] as? String {
            let firstLine = userText
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let firstLine {
                payload["lastUserInput"] = String(firstLine.prefix(240))
            }
        }
        if let toolCall, !toolName.isEmpty {
            var sanitizedTool: [String: Any] = ["name": String(toolName.prefix(128))]
            if let id = toolCall["id"] as? String, !id.isEmpty {
                sanitizedTool["id"] = String(id.prefix(128))
            }
            let summary = (toolArgs["toolSummary"] as? String)
                ?? (toolArgs["Description"] as? String)
                ?? (toolArgs["Role"] as? String)
            if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                sanitizedTool["summary"] = String(summary.prefix(200))
            }
            if awaitsDecision, let boundedArgs = ClaudeCodeHookIO.bounded(toolArgs, maximumBytes: 131_072) {
                sanitizedTool["args"] = boundedArgs
            }
            payload["toolCall"] = sanitizedTool
        }
        if let owner = ClaudeHookProcess.owner(startingAt: getppid(), lookup: ClaudeHookProcess.lookup) {
            payload["hookProcessId"] = Int(owner.pid)
            payload["hookProcessName"] = owner.name
        }

        let eventID = UUID().uuidString.lowercased()
        let envelope: [String: Any] = [
            "authenticationToken": route.authenticationToken,
            "eventID": eventID,
            "kind": "hook",
            "awaitDecision": awaitsDecision,
            "payload": payload
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              var data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        data.append(0x0A)
        let client = ClaudeCodeSocketClient()
        guard client.connect(path: route.socketPath, timeout: awaitsDecision ? 0.5 : 0.35),
              client.send(data, timeout: awaitsDecision ? 1.0 : 0.5) else {
            return
        }
        guard let ack = client.readLine(until: Date().addingTimeInterval(awaitsDecision ? 2.0 : 0.5)),
              ack["eventID"] as? String == eventID,
              ack["accepted"] as? Bool == true else {
            return
        }
        guard awaitsDecision, ack["pending"] as? Bool == true else {
            return
        }

        let timeout = min(max(route.decisionTimeoutSeconds ?? 120, 5), 120)
        guard let reply = client.readLine(until: Date().addingTimeInterval(timeout)),
              reply["eventID"] as? String == eventID,
              let decisionObj = reply["decision"] as? [String: Any],
              let decisionValue = decisionObj["decision"] as? String else {
            return
        }

        var hookOut: [String: Any] = [:]
        switch decisionValue {
        case "auto_approve":
            hookOut["decision"] = "auto_approve"
        case "deny":
            hookOut["decision"] = "deny"
            if let reason = decisionObj["reason"] as? String, !reason.isEmpty {
                hookOut["reason"] = String(reason.prefix(16_384))
            }
        default:
            hookOut["decision"] = "allow"
        }

        if JSONSerialization.isValidJSONObject(hookOut),
           var encoded = try? JSONSerialization.data(withJSONObject: hookOut) {
            encoded.append(0x0A)
            responseData = encoded
        }
    }
}

enum AntigravityStatusLineForwarder {
    static let allowedKeys = [
        "session_id", "sessionId", "agent_state", "agentState",
        "plan_tier", "planTier", "model", "context_window", "contextWindow",
        "quota", "credits", "ai_credits", "aiCredits",
        "useG1Credits", "use_ai_credits", "useAiCredits",
        "enable_ai_credits", "enableAiCredits", "cost"
    ]

    static func run(arguments: [String]) {
        signal(SIGPIPE, SIG_IGN)
        let input = ClaudeCodeHookIO.readStandardInput(maximumBytes: 2_097_152) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        guard arguments.count == 3, arguments[1] == "--configuration",
              let route = ClaudeCodeRoute.read(from: arguments[2]) else {
            return
        }
        if !object.isEmpty {
            record(object, route: route)
        }
        if let command = route.statusLineForwardCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty,
           let output = forward(command: command, input: input) {
            ClaudeCodeHookIO.writeStandardOutput(output)
            return
        }
        if route.statusLineStackWithDefault == false {
            ClaudeCodeHookIO.writeStandardOutput(Data(compactLine(object).utf8))
        }
    }

    private static func record(_ object: [String: Any], route: ClaudeCodeRoute) {
        var snapshot: [String: Any] = ["capturedAt": Date().timeIntervalSince1970]
        for key in allowedKeys {
            if let value = ClaudeCodeHookIO.bounded(object[key], maximumBytes: 16_384) {
                snapshot[key] = value
            }
        }
        if let directory = object["cwd"] as? String, !directory.isEmpty {
            snapshot["cwd"] = String(directory.prefix(4_096))
        }
        guard JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        if let path = route.statusLineSnapshotPath, path.hasPrefix("/") {
            writePrivate(data, to: path)
        }
        let envelope: [String: Any] = [
            "authenticationToken": route.authenticationToken,
            "eventID": UUID().uuidString.lowercased(),
            "kind": "statusLine",
            "awaitDecision": false,
            "payload": snapshot
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              var message = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        message.append(0x0A)
        let client = ClaudeCodeSocketClient()
        if client.connect(path: route.socketPath, timeout: 0.15) {
            _ = client.send(message, timeout: 0.25)
            _ = client.readLine(until: Date().addingTimeInterval(0.25))
        }
    }

    private static func writePrivate(_ data: Data, to path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        var metadata = stat()
        guard lstat(directory, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR else { return }
        let temporary = directory + "/.antigravity-statusline-\(getpid()).tmp"
        let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return false }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count > 0 else { return false }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
        Darwin.close(descriptor)
        if !written || rename(temporary, path) != 0 { unlink(temporary) }
    }

    private static func forward(command: String, input: Data) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let writer = stdinPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        var output = Data()
        let reader = stdoutPipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
                guard output.count + chunk.count <= 1_048_576 else {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    try? reader.close()
                    group.leave()
                    return
                }
                output.append(chunk)
            }
            group.leave()
        }
        let deadline = Date().addingTimeInterval(5)
        if group.wait(timeout: .now() + 5) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
            return nil
        }
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL); return nil }
        return output
    }

    private static func compactLine(_ object: [String: Any]) -> String {
        var parts: [String] = []
        if let model = object["model"] as? [String: Any],
           let name = (model["display_name"] as? String) ?? (model["id"] as? String),
           !name.isEmpty {
            parts.append(name)
        } else if let name = object["model"] as? String, !name.isEmpty {
            parts.append(name)
        }
        if let directory = object["cwd"] as? String {
            let name = (directory as NSString).lastPathComponent
            if !name.isEmpty { parts.append(name) }
        }
        if let quota = object["quota"] as? [String: Any] {
            let fractions = quota.values.compactMap { entry -> Int? in
                guard let dict = entry as? [String: Any],
                      let fraction = dict["remaining_fraction"] as? NSNumber,
                      fraction.doubleValue.isFinite, (0...1).contains(fraction.doubleValue) else { return nil }
                return Int((fraction.doubleValue * 100).rounded())
            }
            if let lowest = fractions.min() {
                parts.append("quota \(lowest)%")
            }
        }
        if let credits = object["credits"] as? NSNumber, credits.doubleValue.isFinite, credits.intValue >= 0 {
            parts.append("AI Credits: \(credits.intValue)")
        } else if let creditsObj = object["credits"] as? [String: Any],
                  let remaining = (creditsObj["remaining"] as? NSNumber) ?? (creditsObj["balance"] as? NSNumber),
                  remaining.doubleValue.isFinite {
            parts.append("AI Credits: \(remaining.intValue)")
        }
        if let context = object["context_window"] as? [String: Any],
           let used = context["used_percentage"] as? NSNumber,
           used.doubleValue.isFinite, (0...100).contains(used.doubleValue) {
            parts.append("ctx \(Int(used.doubleValue.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }
}
