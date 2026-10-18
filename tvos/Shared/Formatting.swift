import Foundation

enum ProgramText {
    /// 20:00 – 00:20
    static func timeRange(_ program: TVProgram) -> String {
        "\(clock(program.start)) – \(clock(program.end))"
    }

    /// 24 saat, iki haneli: 00:20
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

enum DurationText {
    /// 11 sa 34 dk / 45 dk
    static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) dk" }
        return minutes % 60 == 0 ? "\(hours) sa" : "\(hours) sa \(minutes % 60) dk"
    }

    /// 1:02:05 / 12:34
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let (h, m, sec) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
