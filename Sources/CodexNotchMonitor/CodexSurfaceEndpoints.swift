import Foundation
import CoreFoundation
import Darwin

/// Non-secret discovery records published by OneNative's terminal-scoped guardian.
enum CodexSurfaceEndpoints {
    struct ProcessInfo {
        let uid: uid_t
        let parent: Int32
        let executable: String
        let started: Double
    }
    struct Endpoint: Equatable {
        let socket: URL
        let identity: String
    }
    static var root: URL { URL(fileURLWithPath: "/private/tmp/one-native-codex-\(getuid())", isDirectory: true) }

    static func discover(directory: URL = root, process: (Int32) -> ProcessInfo? = inspectProcess,
                         peer: (URL, Int32) -> Bool = verifyPeer) -> [Endpoint] {
        guard privateDirectory(directory),
              let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), children.count <= 128 else { return [] }
        return children.filter { $0.lastPathComponent.hasPrefix("surface-") }.compactMap {
            read($0, process: process, peer: peer)
        }.sorted { $0.socket.path < $1.socket.path }
    }
    private static func privateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
    }
    private static func read(_ directory: URL, process: (Int32) -> ProcessInfo?, peer: (URL, Int32) -> Bool) -> Endpoint? {
        guard privateDirectory(directory) else { return nil }
        let file = directory.appendingPathComponent("runtime.json"), socket = directory.appendingPathComponent("server.sock")
        // Codex 0.166.0 publishes a private symlink to its actual hashed listener.
        let resolvedSocket = socket.resolvingSymlinksInPath()
        var metadata = stat(), socketMetadata = stat(), linkMetadata = stat()
        guard lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, metadata.st_size > 0, metadata.st_size <= 8192,
              lstat(socket.path, &linkMetadata) == 0, linkMetadata.st_uid == getuid(),
              [S_IFSOCK, S_IFLNK].contains(linkMetadata.st_mode & S_IFMT),
              privateDirectory(resolvedSocket.deletingLastPathComponent()),
              lstat(resolvedSocket.path, &socketMetadata) == 0, socketMetadata.st_mode & S_IFMT == S_IFSOCK,
              socketMetadata.st_uid == getuid(), socketMetadata.st_mode & 0o077 == 0,
              let data = try? Data(contentsOf: file), data.count <= 8192,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(value["version"]) == 1, value["socket"] as? String == socket.path,
              let executable = value["executable"] as? String, executable.hasPrefix("/"),
              let ownerPID = pid(value["ownerPID"]), let guardianPID = pid(value["guardianPID"]), let serverPID = pid(value["serverPID"]),
              Set([ownerPID, guardianPID, serverPID]).count == 3,
              let owner = process(ownerPID), let guardian = process(guardianPID), let server = process(serverPID),
              owner.uid == getuid(), guardian.uid == getuid(), server.uid == getuid(),
              guardian.parent == ownerPID, server.parent == guardianPID else { return nil }
        let actual = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard URL(fileURLWithPath: owner.executable).resolvingSymlinksInPath().path == actual,
              URL(fileURLWithPath: server.executable).resolvingSymlinksInPath().path == actual,
              URL(fileURLWithPath: actual).lastPathComponent.lowercased().contains("codex"),
              peer(resolvedSocket, serverPID) else { return nil }
        return .init(socket: resolvedSocket, identity: "\(socket.path):\(owner.started):\(server.started):\(socketMetadata.st_dev):\(socketMetadata.st_ino)")
    }
    private static func pid(_ value: Any?) -> Int32? {
        guard let number = integer(value), number > 1 else { return nil }
        return Int32(number)
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue == Double(number.int64Value) else { return nil }
        return number.intValue
    }
    static func inspectProcess(_ pid: Int32) -> ProcessInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid], info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return .init(uid: info.kp_eproc.e_ucred.cr_uid, parent: info.kp_eproc.e_ppid,
                     executable: String(cString: bytes), started: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
    static func verifyPeer(_ url: URL, _ expectedPID: Int32) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return false }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = url.path.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        var uid: uid_t = 0, gid: gid_t = 0, pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return result == 0 && getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
            && getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid == expectedPID
    }
}
