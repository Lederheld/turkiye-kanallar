import UIKit

/// Kanal logoları bellekte tutulur ve açılışta topluca indirilir; kartlar ve kanal şeridi logoyu
/// beklemeden gösterir (AsyncImage her görünümde yeniden yüklüyordu). Disk önbelleği URLCache'tir.
@MainActor
final class LogoCache: ObservableObject {
    static let shared = LogoCache()

    @Published private(set) var images: [URL: UIImage] = [:]
    private var inFlight: Set<URL> = []
    private static let maxConcurrentDownloads = 6
    private static let publishBatchSize = 8

    func image(for url: URL) -> UIImage? {
        images[url]
    }

    func load(_ url: URL) {
        guard images[url] == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task {
            let image = await Self.download(url)
            inFlight.remove(url)
            if let image { images[url] = image }
        }
    }

    /// Tüm kanal logolarını sınırlı sayıda eşzamanlı istekle indirir.
    func prefetch(_ urls: [URL]) async {
        let missing = urls.filter { images[$0] == nil && !inFlight.contains($0) }
        inFlight.formUnion(missing)
        await withTaskGroup(of: (URL, UIImage?).self) { group in
            var pending = missing[...]
            func addNext() {
                guard let url = pending.popFirst() else { return }
                group.addTask { (url, await Self.download(url)) }
            }
            for _ in 0..<Self.maxConcurrentDownloads { addNext() }
            // Her logoda tüm kartlar yeniden çizilmesin: sekizerli gruplar halinde yayınla
            var batch: [URL: UIImage] = [:]
            for await (url, image) in group {
                inFlight.remove(url)
                if let image { batch[url] = image }
                if batch.count >= Self.publishBatchSize {
                    images.merge(batch) { _, new in new }
                    batch = [:]
                }
                addNext()
            }
            images.merge(batch) { _, new in new }
        }
    }

    private nonisolated static func download(_ url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        // Kodu çözülmüş halde tut: kaydırırken ilk çizimde takılmasın
        return await image.byPreparingForDisplay() ?? image
    }
}
