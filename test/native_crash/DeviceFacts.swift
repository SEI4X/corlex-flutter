import Foundation
// Deterministic OS/build metadata boundary; all SDK state, report and C writer code is real.
struct DeviceFacts {
    var appVersion: String?
    var build: String?
    var osVersion = "test"
    var deviceModel = "test"
    static var architecture = "arm64"
    static func current() -> DeviceFacts {
        let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "default"
        return DeviceFacts(appVersion: mode == "boundary" ? String(repeating: "v", count: 128) : mode == "oversize" ? String(repeating: "v", count: 129) : "0.1.0",
                           build: mode == "boundary" ? String(repeating: "b", count: 32) : mode == "oversize" ? String(repeating: "b", count: 33) : "1")
    }
}
