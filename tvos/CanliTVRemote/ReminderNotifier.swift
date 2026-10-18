import Foundation
import UserNotifications

/// Hatırlatıcılar (Apple TV'de ya da burada kurulan, iCloud'la eşitlenen) program başlamadan bir dakika
/// önce iPhone'da bildirim olur. Bildirime dokununca kanal Apple TV'de açılır.
@MainActor
enum ReminderNotifier {
    private static let lead: TimeInterval = 60
    static let channelKey = "channel"

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func schedule(_ reminders: [Reminder]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        for reminder in reminders.prefix(60) {  // iOS en fazla 64 bekleyen bildirim tutar
            let fireDate = reminder.start.addingTimeInterval(-lead)
            guard fireDate > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(reminder.title) birazdan başlıyor"
            content.body = "\(reminder.channelName) · \(ProgramText.clock(reminder.start)). Dokun, Apple TV'de açılsın."
            content.sound = .default
            content.userInfo = [channelKey: reminder.channelName]
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }
}
