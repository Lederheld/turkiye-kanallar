import Foundation

/// iCloud anahtar-değer deposu üzerinden ayar eşitleme (favoriler, izleme geçmişi, hatırlatıcılar…).
/// Aynı Apple hesabındaki cihazlar (ve Apple TV'de her profil kendi hesabıyla) aynı değerleri görür.
/// iCloud kapalıysa depo yerel kalır; uygulama UserDefaults ile aynen çalışır.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private var handlers: [String: (Any) -> Void] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.applyExternalChanges(keys) }
        }
        store.synchronize()
    }

    /// Başka cihazdan gelen değer `apply` ile uygulanır.
    func register(_ key: String, apply: @escaping (Any) -> Void) {
        handlers[key] = apply
    }

    func value(for key: String) -> Any? {
        store.object(forKey: key)
    }

    func push(_ value: Any?, for key: String) {
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    private func applyExternalChanges(_ keys: [String]) {
        for key in keys {
            guard let handler = handlers[key], let value = store.object(forKey: key) else { continue }
            handler(value)
        }
    }

    // MARK: - Birleştirme

    /// Yerel sıra korunur, buluttaki eksikler sona eklenir.
    static func union(_ local: [String], _ cloud: [String]) -> [String] {
        local + cloud.filter { !local.contains($0) }
    }

    /// İzleme geçmişi: her kanal için son güncellenen kayıt kalır ([puan, zaman]).
    static func mergeHistory(_ local: [String: [Double]], _ cloud: [String: [Double]]) -> [String: [Double]] {
        local.merging(cloud) { mine, theirs in
            (theirs.count == 2 && mine.count == 2 && theirs[1] > mine[1]) ? theirs : mine
        }
    }
}
