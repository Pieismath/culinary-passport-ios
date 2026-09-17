import UIKit
import UserNotifications

/// Notification permission + APNs registration. Remote push delivery needs
/// the paid developer account's entitlement; local "On this day" reminders
/// work today.
enum PushRegistrar {
    /// Ask for permission — only from a moment where the user can see why
    /// (turning on reminders). Returns whether it's granted.
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
        Task { try? await SupabaseBackend.shared.registerDeviceToken(token) }
    }
}

/// APNs callbacks + notification taps into the SwiftUI lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected without the push entitlement.
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: raw) else { return }
        await MainActor.run {
            // A cold launch from the notification can land before any view
            // subscribes, so the link is also parked for the app to collect.
            DeepLinkInbox.pending = url
            NotificationCenter.default.post(name: .stampdOpenURL, object: url)
        }
    }
}

@MainActor
enum DeepLinkInbox {
    static var pending: URL?

    static func take() -> URL? {
        defer { pending = nil }
        return pending
    }
}
