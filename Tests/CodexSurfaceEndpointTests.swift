import Foundation
import Darwin

@main struct CodexSurfaceEndpointTests {
    static var checks = 0
    static func expect(_ value: Bool, _ text: String) { checks += 1; if !value { fatalError(text) } }
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live" {
            let id = CommandLine.arguments[2]
            var found = false
            for endpoint in CodexSurfaceEndpoints.discover() {
                let transport = try CodexProxyTransport(executable: URL(fileURLWithPath: "/Users/zuxinchen/.local/bin/codex"), socketURL: endpoint.socket)
                defer { transport.close() }
                let loaded = try transport.request("thread/loaded/list", [:])["data"] as? [String] ?? []
                if loaded.contains(id) {
                    let thread = try transport.request("thread/read", ["threadId": id, "includeTurns": false])["thread"] as? [String: Any]
                    expect(thread?["canAcceptDirectInput"] as? Bool == true, "native TUI is not accepting direct input")
                    found = true
                }
            }
            expect(found, "Pulse did not discover the exact isolated OneNative surface")
            print("PASS Pulse discovery and readonly proxy to the real scoped Codex TUI")
            return
        }
        let root = URL(fileURLWithPath: "/private/tmp/pulse-cs-" + String(UUID().uuidString.prefix(8)))
        let directory = root.appendingPathComponent("surface-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = directory.appendingPathComponent("server.sock"), file = directory.appendingPathComponent("runtime.json")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path.utf8CString.map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        expect(result == 0 && chmod(socketURL.path, 0o600) == 0, "private socket fixture")
        let original: [String: Any] = ["version": 1, "ownerPID": 100, "guardianPID": 101, "serverPID": 102, "executable": "/fixture/codex", "cwd": "/fixture", "socket": socketURL.path]
        var processes: [Int32: CodexSurfaceEndpoints.ProcessInfo] = [
            100: .init(uid: getuid(), parent: 99, executable: "/fixture/codex", started: 1),
            101: .init(uid: getuid(), parent: 100, executable: "/fixture/python", started: 2),
            102: .init(uid: getuid(), parent: 101, executable: "/fixture/codex", started: 3)]
        func write(_ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: file)
            expect(chmod(file.path, 0o600) == 0, "private manifest")
        }
        func discover() -> [CodexSurfaceEndpoints.Endpoint] { CodexSurfaceEndpoints.discover(directory: root, process: { processes[$0] }, peer: { _, pid in pid == 102 }) }
        try write(original)
        expect(discover().count == 1, "valid owned process chain discovered")
        expect(CodexSurfaceEndpoints.discover(directory: root, process: { processes[$0] }, peer: { _, _ in false }).isEmpty, "different socket peer rejected")
        let old = discover()[0]
        let actualDirectory = directory.appendingPathComponent("native-listener")
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let actualSocket = actualDirectory.appendingPathComponent("native.sock")
        try FileManager.default.moveItem(at: socketURL, to: actualSocket)
        try FileManager.default.createSymbolicLink(at: socketURL, withDestinationURL: actualSocket)
        let linked = discover().first?.socket
        expect(linked?.path == actualSocket.resolvingSymlinksInPath().path, "official private socket symlink resolves to verified listener")
        chmod(actualDirectory.path, 0o755); expect(discover().isEmpty, "symlink into public directory rejected"); chmod(actualDirectory.path, 0o700)
        try FileManager.default.removeItem(at: socketURL)
        try FileManager.default.moveItem(at: actualSocket, to: socketURL)
        processes[102] = .init(uid: getuid(), parent: 101, executable: "/fixture/codex", started: 4)
        expect(discover().first?.identity != old.identity, "process restart changes connection authority")
        for (key, value) in [("version", true as Any), ("ownerPID", true as Any), ("guardianPID", 101.5 as Any), ("serverPID", 100 as Any), ("socket", "/other/server.sock" as Any), ("executable", "/fixture/other" as Any)] {
            var invalid = original; invalid[key] = value; try write(invalid)
            expect(discover().isEmpty, "invalid manifest field rejected: " + key)
        }
        try write(original)
        let saved = processes.removeValue(forKey: 102)
        expect(discover().isEmpty, "dead server rejected")
        processes[102] = saved
        processes[101] = .init(uid: getuid(), parent: 55, executable: "/fixture/python", started: 2)
        expect(discover().isEmpty, "orphan guardian rejected")
        processes[101] = .init(uid: getuid() + 1, parent: 100, executable: "/fixture/python", started: 2)
        expect(discover().isEmpty, "cross-user guardian rejected")
        processes[101] = .init(uid: getuid(), parent: 100, executable: "/fixture/python", started: 2)
        chmod(file.path, 0o644); expect(discover().isEmpty, "public manifest rejected"); chmod(file.path, 0o600)
        chmod(socketURL.path, 0o666); expect(discover().isEmpty, "public socket rejected"); chmod(socketURL.path, 0o600)
        chmod(root.path, 0o755); expect(discover().isEmpty, "public root rejected"); chmod(root.path, 0o700)
        expect(CodexSurfaceEndpoints.inspectProcess(getpid())?.uid == getuid(), "native process metadata available")
        print("PASS scoped Codex endpoint discovery: \(checks) checks")
    }
}
