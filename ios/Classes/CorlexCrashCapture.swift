import Foundation

struct CorlexCrashActivation {
    let directory: URL
    let captureErrorMessages: Bool
    let admit: (@escaping () throws -> Void) throws -> Void
}

/// State admission precedes the reporter mutex. C uses only its admitted immutable header.
final class CorlexCrashCapture {
    static let shared = CorlexCrashCapture()
    private let lock = NSLock()
    private var installed = false
    private var activation: CorlexCrashActivation?
    private var previousHandler: NSUncaughtExceptionHandler?

    func install(_ next: CorlexCrashActivation, owner: String, generation: String) throws {
        lock.lock(); defer { lock.unlock() }
        if activation?.directory == next.directory { activation = next; return }
        corlex_crash_set_enabled(0)
        activation = nil
        guard CorlexNativeCrashWriter.install(next.directory, owner: owner, generation: generation) else {
            throw ProtectedStateError.invalid
        }
        if !installed {
            previousHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { exception in
                CorlexCrashCapture.shared.write(exception)
                CorlexCrashCapture.shared.previousHandler?(exception)
            }
            installed = true
        }
        activation = next
        corlex_crash_set_enabled(1)
    }

    /// Stop C admission before waiting for an exception or the state filesystem lock.
    func setEnabled(_ on: Bool, wipe: Bool) {
        guard !on else { return } // Unscoped activation cannot acquire authority.
        corlex_crash_set_enabled(0)
        lock.lock(); defer { lock.unlock() }
        activation = nil
        corlex_crash_set_enabled(0)
        // Generation cleanup belongs to StateStore, never a cached reporter path.
    }

    private func write(_ exception: NSException) {
        lock.lock(); let admitted = activation; lock.unlock()
        guard let admitted else { return }
        try? admitted.admit {
            self.lock.lock(); defer { self.lock.unlock() }
            guard let current = self.activation, current.directory == admitted.directory else { return }
            CorlexNativeCrashWriter.write(exception, captureErrorMessages: current.captureErrorMessages)
        }
    }
}
