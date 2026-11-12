import Foundation

final class CorlexNativeCrashAccess {
    private let state: CorlexFlutterStateStore
    private let reporter = CorlexCrashCapture.shared
    init(state: CorlexFlutterStateStore) { self.state = state }

    func disable() { reporter.setEnabled(false, wipe: false) }
    func set(_ args: [String: Any]) throws {
        let (owner, generation) = try binding(args)
        if args["enabled"] as? Bool != true {
            try state.scoped(owner, generation, CorlexFlutterScopeOperation(
                run: { _ in self.disable() }, invalidated: disable))
            return
        }
        try state.scoped(owner, generation, CorlexFlutterScopeOperation(run: { scope in
            let directory = try CorlexNativeCrashFiles.directory(in: scope)
            let activation = CorlexCrashActivation(directory: directory,
                captureErrorMessages: args["captureErrorMessages"] as? Bool == true,
                admit: { action in
                    try self.state.scoped(owner, generation, CorlexFlutterScopeOperation(run: { _ in try action() }, invalidated: self.disable))
                })
            try self.reporter.install(activation, owner: owner, generation: generation)
        }, invalidated: disable))
    }
    func pending(_ args: [String: Any]) throws -> [[String: String]] {
        let (owner, generation) = try binding(args)
        return try state.scoped(owner, generation, CorlexFlutterScopeOperation(run: { scope in
            CorlexNativeCrashFiles.pending(try CorlexNativeCrashFiles.directory(in: scope), owner: owner, generation: generation)
        }, invalidated: disable))
    }
    func ack(_ args: [String: Any]) throws {
        let (owner, generation) = try binding(args)
        guard let ids = args["ids"] as? [String] else { throw ProtectedStateError.invalid }
        try state.scoped(owner, generation, CorlexFlutterScopeOperation(run: { scope in
            try CorlexNativeCrashFiles.remove(ids, directory: CorlexNativeCrashFiles.directory(in: scope))
        }, invalidated: disable))
    }
    private func binding(_ args: [String: Any]) throws -> (String, String) {
        guard let owner = args["owner"] as? String, CorlexFlutterStateCodec.ownerValid(owner),
              let generation = args["generation"] as? String, generation.count == 36,
              UUID(uuidString: generation) != nil else { throw ProtectedStateError.invalid }
        return (owner, generation)
    }
}
