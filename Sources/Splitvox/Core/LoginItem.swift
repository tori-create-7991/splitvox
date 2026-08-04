import Foundation
import ServiceManagement

/// Launch at login, registered by the app itself.
///
/// `SMAppService` rather than an entry added by hand: the registration follows
/// the bundle, so it survives a rebuild and can be turned off from inside the
/// app. SelectTrans registered its login item manually and later needed a
/// repair plan when the recorded path went stale.
///
/// Only meaningful for a real `.app` bundle — a bare binary from `swift build`
/// has nothing to register.
enum LoginItem {

    enum Status: Equatable {
        case enabled
        case disabled
        /// macOS wants the user to approve it in System Settings first.
        case requiresApproval
        case unavailable
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// System Settings pane where a pending approval is granted.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
