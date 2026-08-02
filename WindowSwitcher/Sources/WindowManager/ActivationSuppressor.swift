import Foundation

/// Distinguishes the async `didActivateApplicationNotification` caused by our
/// OWN programmatic `app.activate()` from a real user activation (Cmd+Tab,
/// Dock click). The notification is delivered asynchronously — after the
/// `isActivating` flag has already been reset — so we instead remember which
/// PID we just activated and suppress that PID's notification within a short
/// window.
final class ActivationSuppressor {
    private var pendingPID: pid_t?
    private var pendingDate: Date?
    private let window: TimeInterval

    init(suppressionWindow: TimeInterval = 1.5) {
        self.window = suppressionWindow
    }

    /// Record that we are about to programmatically activate `pid`.
    func recordActivation(pid: pid_t, at date: Date = Date()) {
        pendingPID = pid
        pendingDate = date
    }

    /// Returns true if `pid` is the app we just programmatically activated
    /// (i.e. the notification should be suppressed), and clears the pending
    /// state in both cases.
    func shouldSuppress(pid: pid_t, at date: Date = Date()) -> Bool {
        defer { clear() }
        guard let pendingPID, let pendingDate,
              pid == pendingPID,
              date.timeIntervalSince(pendingDate) < window else {
            return false
        }
        return true
    }

    func clear() {
        pendingPID = nil
        pendingDate = nil
    }
}
