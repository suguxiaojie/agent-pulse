import Foundation

struct AntigravityPermissionRequest: Identifiable {
    struct Question: Identifiable, Equatable {
        let id: String
        let text: String
        let options: [String]
        var multiSelect = false
        var descriptions: [String: String] = [:]
    }

    enum Choice {
        case approveOnce
        case answer
        case deny
        case passthrough
    }

    static let decisionTimeoutSeconds: Double = 120

    let id: String
    let conversationID: String
    let surface: AntigravitySurface
    let stepIndex: Int?
    let toolCallID: String?
    let tool: String
    let cwd: String
    let args: [String: Any]
    let questions: [Question]
    var receivedAt = Date()

    var deadline: Date {
        receivedAt.addingTimeInterval(Self.decisionTimeoutSeconds)
    }

    var isQuestion: Bool {
        !questions.isEmpty
    }

    var isCommandStyle: Bool {
        tool == "run_command" || tool.hasPrefix("mcp__") || tool.contains("/")
    }

    var displayToolName: String {
        switch tool {
        case "ask_question": return "提问"
        case "run_command": return "终端命令"
        case "write_file", "write_to_file": return "写入文件"
        case "edit_file", "replace_file_content", "multi_replace_file_content": return "编辑文件"
        case "read_file", "view_file": return "读取文件"
        case "read_url_content": return "读取网页"
        case "search_web": return "网页搜索"
        default:
            if tool.hasPrefix("mcp__") {
                return "MCP · " + tool.dropFirst(5)
            }
            return tool
        }
    }

    var summaryText: String {
        if isQuestion {
            return questions.first?.text ?? "请在灵动岛回答问题"
        }
        switch tool {
        case "run_command":
            let cmd = (args["CommandLine"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = (args["toolSummary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let dir = ((args["Cwd"] as? String) ?? cwd).trimmingCharacters(in: .whitespacesAndNewlines)
            var lines: [String] = []
            if let summary, !summary.isEmpty { lines.append(summary) }
            if !cmd.isEmpty { lines.append("$ " + cmd) }
            if !dir.isEmpty { lines.append("目录：" + dir) }
            return lines.isEmpty ? "执行终端命令" : lines.joined(separator: "\n")

        case "write_file", "write_to_file", "edit_file", "replace_file_content", "multi_replace_file_content", "read_file", "view_file":
            let path = (args["Path"] as? String)
                ?? (args["TargetFile"] as? String)
                ?? (args["AbsolutePath"] as? String)
                ?? ""
            let desc = (args["Description"] as? String) ?? (args["Instruction"] as? String)
            if let desc, !desc.isEmpty, !path.isEmpty {
                return "\(desc)\n\(path)"
            }
            return path.isEmpty ? displayToolName : path

        case "read_url_content":
            return (args["Url"] as? String) ?? (args["url"] as? String) ?? "访问外部网页"

        default:
            return compactDetailPreview
        }
    }

    var detailJSON: String {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return summaryText
        }
        return String(decoding: data, as: UTF8.self)
    }

    private var compactDetailPreview: String {
        let raw = detailJSON
        if raw.count <= 260 { return raw }
        return String(raw.prefix(260)) + "…"
    }

    static func decode(_ message: ClaudeCodeBridgeMessage, receivedAt: Date = Date()) -> Self? {
        guard message.awaitsDecision,
              let object = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any],
              (object["hookEventName"] as? String) == "PreToolUse",
              let conversationID = object["conversationId"] as? String, !conversationID.isEmpty,
              let toolCall = object["toolCall"] as? [String: Any],
              let tool = toolCall["name"] as? String, !tool.isEmpty else {
            return nil
        }
        let args = (toolCall["args"] as? [String: Any]) ?? [:]
        if args["_quotaViewTruncated"] != nil { return nil }

        var parsedQuestions: [Question] = []
        if tool == "ask_question" {
            guard let rawList = args["questions"] as? [[String: Any]],
                  !rawList.isEmpty, rawList.count <= 6 else {
                return nil
            }
            for (idx, item) in rawList.enumerated() {
                guard let qText = (item["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !qText.isEmpty else {
                    return nil
                }
                var labels: [String] = []
                var descriptions: [String: String] = [:]
                if let strOptions = item["options"] as? [String] {
                    labels = strOptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                } else if let objOptions = item["options"] as? [[String: Any]] {
                    for opt in objOptions {
                        if let label = (opt["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                            labels.append(label)
                            if let desc = (opt["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                                descriptions[label] = desc
                            }
                        }
                    }
                }
                var deduplicated: [String] = []
                var seen = Set<String>()
                for label in labels where seen.insert(label).inserted {
                    deduplicated.append(label)
                }
                guard !deduplicated.isEmpty else { return nil }
                let multi = (item["is_multi_select"] as? Bool) ?? (item["multiSelect"] as? Bool) ?? false
                let qID = rawList.count == 1 ? qText : "q\(idx + 1):\(qText)"
                parsedQuestions.append(.init(
                    id: qID,
                    text: qText,
                    options: deduplicated,
                    multiSelect: multi,
                    descriptions: descriptions
                ))
            }
        }

        let transcriptPath = (object["transcriptPath"] as? String) ?? ""
        let surface: AntigravitySurface = {
            if transcriptPath.contains("/antigravity-ide/") { return .ide }
            if transcriptPath.contains("/antigravity-cli/") { return .cli }
            if transcriptPath.contains("/antigravity/") { return .app }
            return .cli
        }()
        let cwd = (object["cwd"] as? String)
            ?? (object["workspacePaths"] as? [String])?.first
            ?? ""

        return .init(
            id: message.eventID,
            conversationID: conversationID,
            surface: surface,
            stepIndex: object["stepIdx"] as? Int,
            toolCallID: toolCall["id"] as? String,
            tool: tool,
            cwd: cwd,
            args: args,
            questions: parsedQuestions,
            receivedAt: receivedAt
        )
    }

    func permitsIslandAnswers(_ answers: [String: String]) -> Bool {
        guard !questions.isEmpty else { return false }
        return questions.allSatisfy { q in
            let raw = (answers[q.id] ?? answers[q.text] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !raw.isEmpty && raw.count <= 4_000 && raw.utf8.count <= 65_536
        }
    }

    func decision(_ choice: Choice, answers: [String: String] = [:]) -> [String: Any]? {
        switch choice {
        case .passthrough:
            return ["decision": "allow"]

        case .approveOnce:
            guard !isQuestion else { return nil }
            return ["decision": "auto_approve"]

        case .answer:
            guard isQuestion, permitsIslandAnswers(answers) else { return nil }
            let formattedLines = questions.enumerated().map { idx, q -> String in
                let val = (answers[q.id] ?? answers[q.text] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(idx + 1). \(q.text) -> \(val)"
            }.joined(separator: "\n")
            let reason = "The user answered your ask_question directly in Agent Pulse (treat these as confirmed user answers and proceed immediately without calling ask_question again for them):\n" + formattedLines
            return [
                "decision": "deny",
                "reason": reason
            ]

        case .deny:
            if isQuestion {
                return [
                    "decision": "deny",
                    "reason": "The user dismissed this question prompt in Agent Pulse."
                ]
            }
            return [
                "decision": "deny",
                "reason": "The user declined this tool execution in Agent Pulse."
            ]
        }
    }
}
