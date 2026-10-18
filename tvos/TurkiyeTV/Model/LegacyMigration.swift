import Foundation
import Security

/// Profil desteği (user-management) açılınca uygulama her Apple TV kullanıcısı için ayrı bir veri
/// klasörü kullanmaya başlar; eski favoriler ve izleme geçmişi ortak klasörde kalır. Profil desteğinden
/// önceki bir derleme `-exportLegacy` ile açılınca verileri kullanıcıdan bağımsız anahtar zincirine
/// koyar; yeni derleme ilk açılışta oradan bir kez alır ve kaydı siler (ilk açan profile geçer).
enum LegacyMigration {
    private static let service = "legacyDefaults"
    private static let account = "v1"
    private static let keys = ["favoriteChannelNames", "recentChannelNames", "watchHistory", "startupBehavior",
                               "sortsByWatchTime", "reminders", "customPlaylistURL"]

    /// Yalnızca `-exportLegacy` ile açılınca (profil desteği olmayan derlemede) çalışır; çalıştıysa true.
    @discardableResult
    static func exportIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("-exportLegacy") else { return false }
        var values: [String: Any] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { values[key] = value }
        }
        NSLog("LegacyMigration export: bulunan anahtarlar %@", values.keys.sorted().joined(separator: ","))
        guard !values.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        else { return true }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        NSLog("LegacyMigration export: %d anahtar, durum %d", values.count, status)
        return true
    }

    /// Mağazalar oluşmadan önce çağrılır: bu profilde veri yoksa eski veriler yazılır.
    static func importIfAvailable() {
        var request = query
        request[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        let defaults = UserDefaults.standard
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        SecItemDelete(query as CFDictionary)
        NSLog("LegacyMigration import: %d anahtar", values.count)
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
