import Darwin
import Foundation

/// Antigravity entry points of the shared activity helper.
///
/// `--antigravity-hook --configuration <route.json>` forwards bounded lifecycle
/// metadata (`SessionStart`, `PreInvocation`, `PostInvocation`, `PostToolUse`, `Stop`)
/// over Codex Pulse's private Unix socket. Antigravity hooks are synchronous and
/// fail-closed, so every exit path prints a valid, non-interfering JSON response.
/// `PreToolUse` is intentionally not registered so Pulse never alters user permission prompts.
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

enum AntigravityHookForwarder {
    static func safeResponse(for event: String) -> Data {
        if event == "Stop" {
            return Data("{\"decision\":\"stop\"}\n".utf8)
        }
        return Data("{}\n".utf8)
    }

    static func run(arguments: [String]) {
        signal(SIGPIPE, SIG_IGN)
        let input = ClaudeCodeHookIO.readStandardInput(maximumBytes: 1_048_576)
        let object = input.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let event = (object["hookEventName"] as? String) ?? ""
        defer {
            ClaudeCodeHookIO.writeStandardOutput(safeResponse(for: event))
        }
        guard arguments.count == 3, arguments[1] == "--configuration",
              let route = ClaudeCodeRoute.read(from: arguments[2]),
              !event.isEmpty,
              let conversationID = object["conversationId"] as? String,
              !conversationID.isEmpty, conversationID.utf8.count <= 256 else {
            return
        }

        var payload: [String: Any] = [
            "hookEventName": String(event.prefix(64)),
            "conversationId": conversationID
        ]
        for key in ["transcriptPath", "modelName", "cwd", "terminationReason"] {
            if let text = object[key] as? String, !text.isEmpty {
                payload[key] = String(text.prefix(4_096))
            }
        }
        if let paths = object["workspacePaths"] as? [Any] {
            let clean = paths.prefix(8).compactMap { ($0 as? String).map { String($0.prefix(4_096)) } }
            if !clean.isEmpty { payload["workspacePaths"] = clean }
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
        if let toolCall = object["toolCall"] as? [String: Any],
           let name = toolCall["name"] as? String, !name.isEmpty {
            var sanitizedTool: [String: Any] = ["name": String(name.prefix(128))]
            if let id = toolCall["id"] as? String, !id.isEmpty {
                sanitizedTool["id"] = String(id.prefix(128))
            }
            if let args = toolCall["args"] as? [String: Any] {
                let summary = (args["toolSummary"] as? String)
                    ?? (args["Description"] as? String)
                    ?? (args["Role"] as? String)
                if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    sanitizedTool["summary"] = String(summary.prefix(200))
                }
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
            "awaitDecision": false,
            "payload": payload
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              var data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        data.append(0x0A)
        let client = ClaudeCodeSocketClient()
        if client.connect(path: route.socketPath, timeout: 0.35),
           client.send(data, timeout: 0.5) {
            _ = client.readLine(until: Date().addingTimeInterval(0.5))
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
