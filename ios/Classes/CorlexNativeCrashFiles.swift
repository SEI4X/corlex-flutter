import Foundation
import Darwin

/// Receipts remain in the original protected scope until Dart acknowledges durable enqueueing.
enum CorlexNativeCrashFiles {
    static let maxFiles = 20
    private static let maxBytes = 256 * 1024

    static func directory(in scope: URL) throws -> URL {
        let owner = scope.deletingLastPathComponent().lastPathComponent
        let scopes = scope.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let expected = scopes.appendingPathComponent(owner, isDirectory: true).appendingPathComponent(scope.lastPathComponent, isDirectory: true)
        guard scope.resolvingSymlinksInPath() == expected else { throw ProtectedStateError.invalid }
        var directory = scope.appendingPathComponent("crashes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let type = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard directory.resolvingSymlinksInPath() == scope.resolvingSymlinksInPath().appendingPathComponent("crashes", isDirectory: true),
              type.isSymbolicLink != true, type.isDirectory == true else {
            throw ProtectedStateError.invalid
        }
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try directory.setResourceValues(flags)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        return directory
    }

    static func pending(_ directory: URL, owner: String, generation: String) -> [[String: String]] {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return [] }
        var results: [[String: String]] = []
        for case let file as URL in entries.prefix(256) {
            guard results.count < maxFiles, let id = id(file), let text = read(file),
                  let line = text.split(separator: "\n").first, line.utf8.count <= 4096,
                  CorlexFlutterStateCodec.depthAllowed(Data(line.utf8), 1),
                  let header = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  header["crash_id"] as? String == id,
                  header["binding_owner"] as? String == owner,
                  header["binding_generation"] as? String == generation else { continue }
            results.append(["id": id, "data": text])
        }
        return results
    }

    static func remove(_ ids: [String], directory: URL) throws {
        guard ids.count <= maxFiles, ids.allSatisfy(validId) else { throw ProtectedStateError.invalid }
        for id in ids {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("crash-\(id).corlex"))
        }
    }

    private static func validId(_ id: String) -> Bool {
        id.count == 36 && id == id.lowercased() && UUID(uuidString: id) != nil
    }
    private static func id(_ file: URL) -> String? {
        let name = file.lastPathComponent
        guard name.hasPrefix("crash-"), name.hasSuffix(".corlex") else { return nil }
        let id = String(name.dropFirst(6).dropLast(7))
        return validId(id) ? id : nil
    }
    private static func read(_ file: URL) -> String? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size <= maxBytes, let bytes = try? handle.read(upToCount: maxBytes + 1),
              bytes.count <= maxBytes else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
