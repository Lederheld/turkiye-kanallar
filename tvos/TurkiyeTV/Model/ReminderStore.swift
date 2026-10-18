import Foundation

struct Reminder: Codable, Hashable, Identifiable {
    let channelName: String
    let title: String
    let start: Date
    let end: Date

    var id: String { "\(channelName)|\(Int(start.timeIntervalSince1970))" }

    init(channel: Channel, program: TVProgram) {
        channelName = channel.name
        title = program.title
        start = program.start
        end = program.end
    }
}

/// Programlar için hatırlatıcılar. tvOS uygulama kapalıyken ekrana bildirim gösteremediği için
/// hatırlatma uygulama açıkken yapılır; açılışta yayında olan hatırlatılmış program varsa o kanal açılır.
@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var reminders: [Reminder] = []
    /// Başlamak üzere ya da yeni başlamış, kullanıcıya gösterilen hatırlatma.
    @Published private(set) var due: Reminder?

    private let defaults = UserDefaults.standard
    private static let defaultsKey = "reminders"
    /// Bu kadar önce uyarılır.
    private static let lead: TimeInterval = 60
    /// Başladıktan bu kadar sonrasına kadar hâlâ uyarılır (uygulama o sırada açılmış olabilir).
    private static let grace: TimeInterval = 5 * 60
    private var dismissed: Set<String> = []
    private var checkTask: Task<Void, Never>?

    init() {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = saved.filter { $0.end > Date() }
        }
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func isSet(_ channel: Channel, _ program: TVProgram) -> Bool {
        reminders.contains { $0.id == Reminder(channel: channel, program: program).id }
    }

    func toggle(_ channel: Channel, _ program: TVProgram) {
        let reminder = Reminder(channel: channel, program: program)
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders.remove(at: index)
        } else {
            reminders.append(reminder)
            reminders.sort { $0.start < $1.start }
        }
        save()
    }

    /// Şu an yayında olan hatırlatılmış program (açılışta o kanal açılır).
    var live: Reminder? {
        let now = Date()
        return reminders.first { $0.start <= now && now < $0.end }
    }

    func dismissDue() {
        if let due { dismissed.insert(due.id) }
        due = nil
    }

    private func check() {
        let now = Date()
        let expired = reminders.filter { $0.end <= now }
        if !expired.isEmpty {
            reminders.removeAll { $0.end <= now }
            save()
        }
        let next = reminders.first { reminder in
            !dismissed.contains(reminder.id)
                && reminder.start.timeIntervalSince(now) <= Self.lead
                && now.timeIntervalSince(reminder.start) <= Self.grace
        }
        if next != due { due = next }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
