import SwiftUI
import UserNotifications

/// iPhone'daki Canlı TV: ev ağındaki Apple TV için kumanda, yayın akışı ve hatırlatıcı bildirimleri.
@main
struct CanliTVRemoteApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var store = PlaylistStore()
    @StateObject private var guide = ProgramGuide()
    @StateObject private var reminders = ReminderStore()
    @StateObject private var remote = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteRootView()
                .environmentObject(store)
                .environmentObject(guide)
                .environmentObject(reminders)
                .environmentObject(remote)
                .tint(Theme.accent)
                .task {
                    delegate.remote = remote
                    remote.start()
                    await ReminderNotifier.requestAuthorization()
                    ReminderNotifier.schedule(reminders.reminders)
                    await store.reloadIfStale()
                    await guide.refreshIfNeeded(for: store.channels, summaryURL: store.epgSummaryURL)
                }
                .onChange(of: reminders.reminders) { _, list in ReminderNotifier.schedule(list) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await remote.refresh()
                        await store.reloadIfStale()
                        await guide.refreshIfNeeded(for: store.channels, summaryURL: store.epgSummaryURL)
                    }
                }
        }
    }
}

/// Bildirime dokununca kanal Apple TV'de açılır.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var remote: RemoteClient?
    @MainActor private var pendingChannel: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let name = response.notification.request.content.userInfo[ReminderNotifier.channelKey] as? String else { return }
        await MainActor.run { IntentRouter.shared.requestedChannelName = name }
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.18, blue: 0.33)
}
