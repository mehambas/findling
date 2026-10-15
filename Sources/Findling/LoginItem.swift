import ServiceManagement
import SwiftUI

/// The login item can also be switched off in System Settings, so the status is read again whenever Settings shows it.
@MainActor final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var failure: String?

    var enabled: Bool { status == .enabled || status == .requiresApproval }
    var detail: String {
        if let failure { return failure }
        if status == .requiresApproval { return "Allow Findling in System Settings › General › Login Items." }
        return "Starts Findling in the menu bar when you log in."
    }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            failure = nil
        } catch {
            failure = "macOS did not change the login item: \(error.localizedDescription)"
        }
        refresh()
    }
}
