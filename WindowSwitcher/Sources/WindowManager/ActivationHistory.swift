import AppKit

/// Tracks application activation events via NSWorkspace notifications.
/// Exposes a callback that fires whenever an app becomes active,
/// providing the PID of the activated application.
final class ActivationHistory {
    /// Called when an app receives activation (Cmd+Tab, Dock click, etc.).
    var onAppActivated: ((pid_t) -> Void)?

    private var observer: NSObjectProtocol?

    func start() {
        logDebug("ActivationHistory: starting observation")
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                logDebug("ActivationHistory: notification without app info")
                return
            }
            let pid = app.processIdentifier
            let name = app.localizedName ?? "?"
            logDebug("ActivationHistory: app activated [\(name)] pid=\(pid)")
            self.onAppActivated?(pid)
        }
        logDebug("ActivationHistory: started OK")
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
            logDebug("ActivationHistory: stopped")
        }
    }
}
