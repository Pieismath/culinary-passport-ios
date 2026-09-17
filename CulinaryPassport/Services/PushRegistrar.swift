import UIKit
import UserNotifications

/// v1.2 push wiring: request permission, register with APNs, store the device
/// token in `device_tokens` so the notify-group edge function can fan out.
///
/// NOTE: real delivery needs the Push Notifications capability + an APNs key,
/// which require a paid Apple Developer account. Until then this registers
/// gracefully (simulators receive a token on iOS 16+; delivery is stubbed
/// server-side). Test locally with `xcrun simctl push`.
enum PushRegistrar {
    /// Ask for permission — only from a moment where the user can see why
    /// (e.g. turning on "On this day" reminders). Returns whether it's granted.
    @discardableResult
    static func requestAndRegister() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
        return granted
    }

    /// Keep the stored device token fresh for users who already said yes,
    /// without ever showing a prompt.
    static func registerIfAuthorized() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    static func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await SupabaseService.shared.registerDeviceToken(token) }
    }
}

/// Hook APNs callbacks into the SwiftUI app lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrar.didRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected without the push entitlement — fine during scaffolding.
        print("APNs registration failed: \(error.localizedDescription)")
    }
}
