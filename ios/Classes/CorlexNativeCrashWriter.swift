import Foundation

/// JSON allocation stays outside the async-signal-safe C handler.
enum CorlexNativeCrashWriter {
    static func install(_ directory: URL, owner: String, generation: String) -> Bool {
        let id = UUID().uuidString.lowercased()
        let facts = DeviceFacts.current()
        let header: [String: Any] = [
            "v": 1, "crash_id": id, "kind": "native", "fatal": true, "platform": "ios",
            "binding_owner": owner, "binding_generation": generation,
            "arch": DeviceFacts.architecture,
            "app_version": metadata(facts.appVersion ?? "", limit: 128),
            "build": metadata(facts.build ?? "", limit: 32),
            "os_version": metadata(facts.osVersion, limit: 64),
            "device_model": metadata(facts.deviceModel, limit: 64),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return false }
        let path = directory.appendingPathComponent("crash-\(id).corlex").path
        return corlex_crash_install(path, String(json.dropLast()) + ",") == 1
    }

    static func write(_ exception: NSException, captureErrorMessages: Bool) {
        let fd = corlex_crash_open_report()
        guard fd >= 0 else { return }
        defer { close(fd) }
        var message = captureErrorMessages ? String((exception.reason ?? "").prefix(512)) : "Error details omitted"
        while message.utf8.count > 512 { message.removeLast() }
        guard let data = try? JSONEncoder().encode(message), let json = String(data: data, encoding: .utf8) else { return }
        corlex_crash_write_header(fd, "ns_exception", "NativeError", String(json.dropFirst().dropLast()))
        let addresses = exception.callStackReturnAddresses.prefix(100).map { $0.uintValue }
        addresses.withUnsafeBufferPointer {
            corlex_crash_write_frames(fd, $0.baseAddress, Int32($0.count), 1)
        }
    }

    private static func metadata(_ value: String, limit: Int) -> String {
        value.utf8.count <= limit ? value : ""
    }
}
