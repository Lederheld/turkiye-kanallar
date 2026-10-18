import Foundation

struct ScheduledProgram: Identifiable {
    let channel: Channel
    let program: TVProgram

    var id: String { Reminder(channel: channel, program: program).id }
}

@MainActor
enum Tonight {
    /// Akşam kuşağı: 19:45–21:00 arasında başlayan uzun yapımlar (dizi, film, maç), henüz bitmemiş olanlar.
    /// Kanallar izleme süresine göre sıralı (ayar açıksa).
    static func programs(store: PlaylistStore, guide: ProgramGuide, now: Date = Date()) -> [ScheduledProgram] {
        let calendar = Calendar.current
        guard let from = calendar.date(bySettingHour: 19, minute: 45, second: 0, of: now),
              let to = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now) else { return [] }
        let minimumLength: TimeInterval = 75 * 60
        var result: [ScheduledProgram] = []
        for channel in store.ordered(store.channels) {
            let match = guide.programs(for: channel).first { program in
                program.start >= from && program.start <= to && program.end > now
                    && program.end.timeIntervalSince(program.start) >= minimumLength
            }
            if let match { result.append(ScheduledProgram(channel: channel, program: match)) }
        }
        return Array(result.prefix(16))
    }
}
