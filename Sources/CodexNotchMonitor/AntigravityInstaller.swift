import CryptoKit
import Darwin
import Foundation

/// Owns Codex Pulse's isolated `"codex-pulse"` entry in `~/.gemini/config/hooks.json`
/// and optional `statusLine` entry in `~/.gemini/antigravity-cli/settings.json`.
/// Never reads credentials, never installs `PreToolUse`, backs up files before first edit,
/// and restores original statusLine on disable/uninstall.
struct AntigravityInstaller: Sendable {
    enum InstallationError: LocalizedError, Equatable {
        case helperUnavailable
        case invalidConfigurationFile
        case settingsChanged
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .helperUnavailable:
                return "当前 Agent Pulse 构建中缺少活动辅助程序。"
            case .invalidConfigurationFile:
                return "Antigravity 配置文件不是可安全保留的 JSON 对象，已放弃修改。"
            case .settingsChanged:
                return "Antigravity 配置正在被其他程序更新，请稍后重试。"
            case .writeFailed:
                return "无法写入 Antigravity 连接配置。"
            }
        }
    }

    struct Configuration: Equatable, Sendable {
        var hooks: Bool
        var statusLine: Bool
    }

    struct State: Equatable, Sendable {
        var hooksInstalled = false
        var statusLineInstalled = false
        var hooksFileExists = false
        var cliSettingsExist = false
    }

    static let hookKey = "codex-pulse"
    static let flatEvents = ["SessionStart", "PreInvocation", "PostInvocation", "Stop"]
    private static let helperName = "ClaudePulseHelper"

    let geminiDirectory: URL
    let hooksURL: URL
    let cliSettingsURL: URL
    let socketURL: URL
    let authenticationToken: String
    let bundledHelperURL: URL
    let installedHelperURL: URL
    let routeURL: URL
    let statusLineSnapshotURL: URL
    let originalStatusLineURL: URL
    let oneNativeStatusLineDirectories: [URL]
    private let supportDirectory: URL

    init(
        socketURL: URL,
        authenticationToken: String,
        geminiDirectory: URL? = nil,
        supportDirectory: URL? = nil,
        helperURL: URL? = nil,
        oneNativeStatusLineDirectories: [URL]? = nil,
        channelIdentifier: String = Bundle.main.bundleIdentifier ?? "com.coverai.codex-notch-monitor"
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = (geminiDirectory ?? home.appendingPathComponent(".gemini", isDirectory: true)).standardizedFileURL
        self.geminiDirectory = root
        self.hooksURL = root
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("hooks.json")
            .resolvingSymlinksInPath()
        self.cliSettingsURL = root
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("settings.json")
            .resolvingSymlinksInPath()
        self.socketURL = socketURL
        self.authenticationToken = authenticationToken
        self.bundledHelperURL = helperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers")
            .appendingPathComponent(Self.helperName)

        let rootHash = String(
            SHA256.hash(data: Data(root.path.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
        )
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexNotchMonitor", isDirectory: true)
            .appendingPathComponent("Channels", isDirectory: true)
            .appendingPathComponent(channelIdentifier, isDirectory: true)
            .appendingPathComponent("antigravity-" + rootHash, isDirectory: true)
        self.supportDirectory = support
        self.installedHelperURL = support.appendingPathComponent(Self.helperName)
        self.routeURL = support.appendingPathComponent("AntigravityRoute.json")
        self.statusLineSnapshotURL = support.appendingPathComponent("antigravity-statusline.json")
        self.originalStatusLineURL = support.appendingPathComponent("antigravity-statusline-original.json")
        if let explicitDirs = oneNativeStatusLineDirectories {
            self.oneNativeStatusLineDirectories = explicitDirs
        } else if geminiDirectory == nil {
            let uid = getuid()
            let primary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cli-agents-\(uid)/agy-statusline", isDirectory: true)
                .standardizedFileURL
            let fallback = URL(fileURLWithPath: "/private/tmp/cli-agents-\(uid)/agy-statusline", isDirectory: true)
                .standardizedFileURL
            self.oneNativeStatusLineDirectories = primary.path == fallback.path ? [primary] : [primary, fallback]
        } else {
            self.oneNativeStatusLineDirectories = []
        }
    }

    var hookCommand: String {
        [quote(installedHelperURL.path), "--antigravity-hook", "--configuration", quote(routeURL.path)].joined(separator: " ")
    }

    var statusLineCommand: String {
        [quote(installedHelperURL.path), "--antigravity-statusline", "--configuration", quote(routeURL.path)].joined(separator: " ")
    }

    func state() -> State {
        let fm = FileManager.default
        let hooksRoot = (try? readJSONObject(at: hooksURL).root) ?? [:]
        let ownedHook = hooksRoot[Self.hookKey] as? [String: Any]
        let hooksInstalled = isExpectedHookSpec(ownedHook)
            && routeExists
            && fm.isExecutableFile(atPath: installedHelperURL.path)

        let cliRoot = (try? readJSONObject(at: cliSettingsURL).root) ?? [:]
        let statusLineCmd = (cliRoot["statusLine"] as? [String: Any])?["command"] as? String
        let statusLineEnabled = ((cliRoot["statusLine"] as? [String: Any])?["enabled"] as? Bool) ?? true
        let statusInstalled = statusLineEnabled
            && statusLineCmd.map(ownsStatusLine) == true
            && routeExists
            && fm.isExecutableFile(atPath: installedHelperURL.path)

        return State(
            hooksInstalled: hooksInstalled,
            statusLineInstalled: statusInstalled,
            hooksFileExists: fm.fileExists(atPath: hooksURL.path),
            cliSettingsExist: fm.fileExists(atPath: cliSettingsURL.path)
        )
    }

    private var routeExists: Bool {
        var metadata = stat()
        return lstat(routeURL.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
    }

    // MARK: - Install & Uninstall

    func install(_ configuration: Configuration) throws {
        guard FileManager.default.isExecutableFile(atPath: bundledHelperURL.path) else {
            throw InstallationError.helperUnavailable
        }
        try withLock {
            try installHelper()
            let cliResult = try configureCLISettings(statusLine: configuration.statusLine)
            try configureHooks(enabled: configuration.hooks)
            try writeRoute(forwardCommand: cliResult.forwardCommand, stackWithDefault: cliResult.stackWithDefault)
            if !configuration.statusLine {
                try? FileManager.default.removeItem(at: originalStatusLineURL)
            }
        }
    }

    func uninstall() throws {
        try withLock {
            _ = try configureCLISettings(statusLine: false)
            try configureHooks(enabled: false)
            for url in [routeURL, statusLineSnapshotURL, originalStatusLineURL, installedHelperURL]
                where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Hooks Configuration (`~/.gemini/config/hooks.json`)

    private func configureHooks(enabled: Bool) throws {
        for attempt in 0..<3 {
            let snapshot = try readJSONObject(at: hooksURL)
            if !enabled && snapshot.revision == nil { return }
            var root = snapshot.root
            if enabled {
                root[Self.hookKey] = makeHookSpec()
            } else {
                guard let current = root[Self.hookKey] else { return }
                // Only remove the entry if it exists as our named key.
                if let dict = current as? [String: Any], !ownsHookObject(dict) {
                    return
                }
                root.removeValue(forKey: Self.hookKey)
            }
            if NSDictionary(dictionary: root).isEqual(to: snapshot.root) {
                try validateRevision(snapshot.revision, at: hooksURL)
                return
            }
            do {
                try writeJSONObject(root, to: hooksURL, defaultMode: S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH, expectedRevision: snapshot.revision)
                return
            } catch InstallationError.settingsChanged where attempt < 2 {
                continue
            }
        }
        throw InstallationError.settingsChanged
    }

    private func makeHookSpec() -> [String: Any] {
        let handler: [String: Any] = [
            "type": "command",
            "command": hookCommand,
            "timeout": 5
        ]
        var spec: [String: Any] = ["enabled": true]
        for event in Self.flatEvents {
            spec[event] = [handler]
        }
        spec["PostToolUse"] = [
            [
                "matcher": "*",
                "hooks": [handler]
            ] as [String: Any]
        ]
        return spec
    }

    private func isExpectedHookSpec(_ spec: [String: Any]?) -> Bool {
        guard let spec else { return false }
        return NSDictionary(dictionary: spec).isEqual(to: makeHookSpec())
    }

    private func ownsHookObject(_ dict: [String: Any]) -> Bool {
        for event in Self.flatEvents {
            if let list = dict[event] as? [[String: Any]],
               list.contains(where: { ownsHookCommand($0["command"] as? String ?? "") }) {
                return true
            }
        }
        if let groups = dict["PostToolUse"] as? [[String: Any]] {
            for group in groups {
                if let hooks = group["hooks"] as? [[String: Any]],
                   hooks.contains(where: { ownsHookCommand($0["command"] as? String ?? "") }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - CLI StatusLine Configuration (`~/.gemini/antigravity-cli/settings.json`)

    private func configureCLISettings(statusLine: Bool) throws -> (forwardCommand: String?, stackWithDefault: Bool) {
        for attempt in 0..<3 {
            let snapshot = try readJSONObject(at: cliSettingsURL)
            if !statusLine && snapshot.revision == nil { return (nil, true) }
            var root = snapshot.root
            if let existing = root["statusLine"], !(existing is [String: Any]) {
                throw InstallationError.invalidConfigurationFile
            }

            var forwardCommand: String?
            var stackWithDefault = true
            if statusLine {
                if let current = root["statusLine"] as? [String: Any],
                   !ownsStatusLine(current["command"] as? String ?? "") {
                    let encoded = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
                    try writePrivate(encoded, to: originalStatusLineURL)
                }
                let savedOriginal = readOriginalStatusLine()
                if (savedOriginal?["enabled"] as? Bool) != false {
                    forwardCommand = savedOriginal?["command"] as? String
                }
                if let savedStack = savedOriginal?["stack_with_default"] as? Bool {
                    stackWithDefault = savedStack
                }
                root["statusLine"] = [
                    "enabled": true,
                    "stack_with_default": stackWithDefault,
                    "type": "command",
                    "command": statusLineCommand
                ] as [String: Any]
            } else if let current = root["statusLine"] as? [String: Any],
                      ownsStatusLine(current["command"] as? String ?? "") {
                if let savedOriginal = readOriginalStatusLine() {
                    root["statusLine"] = savedOriginal
                } else {
                    root.removeValue(forKey: "statusLine")
                }
            } else {
                return (nil, true)
            }

            if NSDictionary(dictionary: root).isEqual(to: snapshot.root) {
                try validateRevision(snapshot.revision, at: cliSettingsURL)
                return (forwardCommand, stackWithDefault)
            }
            do {
                try writeJSONObject(root, to: cliSettingsURL, defaultMode: S_IRUSR | S_IWUSR, expectedRevision: snapshot.revision)
                return (forwardCommand, stackWithDefault)
            } catch InstallationError.settingsChanged where attempt < 2 {
                continue
            }
        }
        throw InstallationError.settingsChanged
    }

    private func readOriginalStatusLine() -> [String: Any]? {
        guard let data = try? Data(contentsOf: originalStatusLineURL), data.count <= 65_536 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Route & Helper Files

    private func writeRoute(forwardCommand: String?, stackWithDefault: Bool) throws {
        var route: [String: Any] = [
            "version": 1,
            "socketPath": socketURL.path,
            "authenticationToken": authenticationToken,
            "interactiveApprovals": false,
            "decisionTimeoutSeconds": 5,
            "statusLineSnapshotPath": statusLineSnapshotURL.path,
            "statusLineStackWithDefault": stackWithDefault
        ]
        if let forwardCommand, !forwardCommand.isEmpty {
            route["statusLineForwardCommand"] = forwardCommand
        }
        let data = try JSONSerialization.data(withJSONObject: route, options: [.sortedKeys])
        if (try? Data(contentsOf: routeURL)) != data {
            try writePrivate(data, to: routeURL)
        }
    }

    private func installHelper() throws {
        let source = try Data(contentsOf: bundledHelperURL)
        if (try? Data(contentsOf: installedHelperURL)) == source,
           FileManager.default.isExecutableFile(atPath: installedHelperURL.path) {
            return
        }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        chmod(supportDirectory.path, S_IRWXU)
        try writeAtomically(source, to: installedHelperURL, mode: S_IRWXU, preservingModeOf: nil) {}
    }

    private func readJSONObject(at url: URL) throws -> (root: [String: Any], revision: Data?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return ([:], nil) }
        guard let size = try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue <= 8_388_608 else {
            throw InstallationError.invalidConfigurationFile
        }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return ([:], data)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallationError.invalidConfigurationFile
        }
        return (object, data)
    }

    private func writeJSONObject(
        _ root: [String: Any],
        to url: URL,
        defaultMode: mode_t,
        expectedRevision: Data?
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try validateRevision(expectedRevision, at: url)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("codex-pulse-backup")
            if !fm.fileExists(atPath: backup.path) {
                var backupStat = stat()
                let originalData = try Data(contentsOf: url)
                let backupMode: mode_t = lstat(url.path, &backupStat) == 0 ? (backupStat.st_mode & 0o777) : defaultMode
                try writeAtomically(originalData, to: backup, mode: backupMode, preservingModeOf: nil) {}
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try writeAtomically(data, to: url, mode: defaultMode, preservingModeOf: url) {
            try validateRevision(expectedRevision, at: url)
        }
    }

    private func validateRevision(_ expected: Data?, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == expected else {
                throw InstallationError.settingsChanged
            }
        } else if expected != nil {
            throw InstallationError.settingsChanged
        }
    }

    private func writePrivate(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        try writeAtomically(data, to: destination, mode: S_IRUSR | S_IWUSR, preservingModeOf: nil) {}
    }

    private func writeAtomically(
        _ data: Data,
        to destination: URL,
        mode: mode_t,
        preservingModeOf existing: URL?,
        beforeRename: () throws -> Void
    ) throws {
        var resolvedMode = mode
        var existingStat = stat()
        if let existing, lstat(existing.path, &existingStat) == 0 {
            resolvedMode = existingStat.st_mode & 0o777
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            resolvedMode
        )
        guard descriptor >= 0 else { throw InstallationError.writeFailed }
        var closed = false
        defer {
            if !closed { Darwin.close(descriptor) }
            unlink(temporary.path)
        }
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count > 0 else { throw InstallationError.writeFailed }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
        fchmod(descriptor, resolvedMode)
        _ = fsync(descriptor)
        Darwin.close(descriptor)
        closed = true
        try beforeRename()
        guard rename(temporary.path, destination.path) == 0 else {
            throw InstallationError.writeFailed
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        chmod(supportDirectory.path, S_IRWXU)
        let lockPath = supportDirectory.appendingPathComponent("installer.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw InstallationError.writeFailed }
        defer {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw InstallationError.writeFailed }
        return try body()
    }

    private func ownsHookCommand(_ command: String) -> Bool {
        owns(command, flag: "--antigravity-hook")
    }

    private func ownsStatusLine(_ command: String) -> Bool {
        owns(command, flag: "--antigravity-statusline")
    }

    private func owns(_ command: String, flag: String) -> Bool {
        command.contains(installedHelperURL.path)
            && command.contains(flag)
            && command.contains(routeURL.path)
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
