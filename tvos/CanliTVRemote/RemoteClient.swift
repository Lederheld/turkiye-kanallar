import Foundation
import Network

/// Ev ağındaki Apple TV'yi (Canlı TV açıkken) bulur ve komut gönderir.
@MainActor
final class RemoteClient: ObservableObject {
    enum Status: Equatable {
        case searching
        case ready(tvName: String)
        /// iCloud'daki ortak anahtar henüz gelmedi (Apple TV'de uygulama hiç açılmamış ya da iCloud kapalı).
        case noKey
        /// Apple TV anahtarı kabul etmedi: farklı Apple hesabı/profil.
        case unauthorized
        case unreachable
    }

    @Published private(set) var status: Status = .searching
    /// Apple TV'de şu an oynayan kanal.
    @Published private(set) var nowPlaying: String?

    private var browser: NWBrowser?
    /// Ağda bulunan Apple TV'ler (aynı cihaz birden çok kez de görünebilir).
    private var endpoints: [NWEndpoint] = []
    /// En son yanıt veren; önce o denenir.
    private var preferred: NWEndpoint?
    private static let timeout: Duration = .seconds(4)

    private var key: String? {
        CloudSync.shared.value(for: RemoteProtocol.keyName) as? String
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteProtocol.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                MainActor.assumeIsolated {
                    self?.browser?.cancel()
                    self?.browser = nil
                    self?.status = .unreachable
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func refresh() async {
        await send(.state)
    }

    func play(_ channel: Channel) async {
        await send(.play, channel: channel.name)
    }

    func zap(_ offset: Int) async {
        await send(.zap, offset: offset)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        endpoints = results.map(\.endpoint)
        if let preferred, !endpoints.contains(preferred) { self.preferred = nil }
        guard !endpoints.isEmpty else {
            status = .unreachable
            return
        }
        Task { await refresh() }
    }

    private func send(_ command: RemoteRequest.Command, channel: String? = nil, offset: Int? = nil) async {
        guard let key else {
            status = .noKey
            return
        }
        // Siri ya da bildirimle soğuk açılışta Apple TV henüz bulunmamış olabilir: kısa süre beklenir
        for _ in 0..<20 where endpoints.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let candidates = (preferred.map { [$0] } ?? []) + endpoints.filter { $0 != preferred }
        guard !candidates.isEmpty else {
            status = browser == nil ? .searching : .unreachable
            return
        }
        var rejected = false
        // Her denemede imza yeniden: zaman damgası taze kalsın
        for endpoint in candidates {
            let request = RemoteRequest.signed(command, channel: channel, offset: offset, key: key)
            guard let response = await Self.exchange(request, with: endpoint) else { continue }
            guard response.ok else {
                rejected = true  // başka profildeki/hesaptaki bir Apple TV olabilir; sıradakine bak
                continue
            }
            preferred = endpoint
            status = .ready(tvName: Self.name(of: endpoint))
            nowPlaying = response.channel
            return
        }
        status = rejected ? .unauthorized : .unreachable
    }

    private static func name(of endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return "Apple TV"
    }

    /// Tek istek, tek yanıt; bağlantı her seferinde yeniden açılır (komutlar seyrek).
    private static func exchange(_ request: RemoteRequest, with endpoint: NWEndpoint) async -> RemoteResponse? {
        guard var payload = try? JSONEncoder().encode(request) else { return nil }
        payload.append(0x0A)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let exchange = Exchange(connection: connection)
        let timeout = Task {
            try? await Task.sleep(for: Self.timeout)
            exchange.finish(nil)
        }
        defer { timeout.cancel() }
        return await exchange.run(sending: payload)
    }

    /// NWConnection geri çağrılarını tek bir async sonuca bağlar.
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RemoteResponse?, Never>?
        private var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }

        func run(sending payload: Data) async -> RemoteResponse? {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.connection.send(content: payload, completion: .contentProcessed { _ in })
                        self?.receive()
                    case .failed, .cancelled:
                        self?.finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if let newline = self.buffer.firstIndex(of: 0x0A) {
                    self.finish(try? JSONDecoder().decode(RemoteResponse.self, from: self.buffer[..<newline]))
                } else if isComplete || error != nil {
                    self.finish(nil)
                } else {
                    self.receive()
                }
            }
        }

        func finish(_ response: RemoteResponse?) {
            let continuation = lock.withLock {
                let current = self.continuation
                self.continuation = nil
                return current
            }
            guard let continuation else { return }
            connection.cancel()
            continuation.resume(returning: response)
        }
    }
}
