import Foundation
import Network
import UIKit

/// iPhone kumandasını dinler (bkz. RemoteProtocol). Gelen istekler Siri ile aynı yoldan (IntentRouter)
/// arayüze iletilir. Uygulama arka plana geçince sistem dinleyiciyi askıya alır; öndeyken çalışır.
@MainActor
final class RemoteServer {
    static let shared = RemoteServer()

    private var listener: NWListener?
    private var buffers: [ObjectIdentifier: Data] = [:]
    private static let defaultsKey = "remoteKey"

    /// iPhone ile paylaşılan anahtar: ilk açılışta üretilir, iCloud'a yazılır.
    private lazy var key: String = {
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) { return saved }
        if let cloud = CloudSync.shared.value(for: RemoteProtocol.keyName) as? String {
            UserDefaults.standard.set(cloud, forKey: Self.defaultsKey)
            return cloud
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let created = Data(bytes).base64EncodedString()
        UserDefaults.standard.set(created, forKey: Self.defaultsKey)
        return created
    }()

    func start() {
        guard listener == nil else { return }
        // iCloud'daki anahtar her açılışta yeniden yazılır (iCloud sonradan açılmış olabilir)
        CloudSync.shared.push(key, for: RemoteProtocol.keyName)
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: UIDevice.current.name, type: RemoteProtocol.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated {
                        self?.listener?.cancel()
                        self?.listener = nil
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("RemoteServer: dinleyici açılamadı: %@", error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let id = ObjectIdentifier(connection)
                if let data { self.buffers[id, default: Data()].append(data) }
                while let newline = self.buffers[id]?.firstIndex(of: 0x0A) {
                    let line = self.buffers[id]![..<newline]
                    self.buffers[id]!.removeSubrange(...newline)
                    self.handle(Data(line), on: connection)
                }
                if isComplete || error != nil || (self.buffers[id]?.count ?? 0) > 64 * 1024 {
                    self.buffers[id] = nil
                    connection.cancel()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func handle(_ line: Data, on connection: NWConnection) {
        let router = IntentRouter.shared
        var response = RemoteResponse(ok: false)
        if let request = try? JSONDecoder().decode(RemoteRequest.self, from: line),
           RemoteProtocol.isValid(request, key: key) {
            switch request.command {
            case .state:
                break
            case .play:
                if let channel = request.channel { router.requestedChannelName = channel }
            case .zap:
                router.zapRequest = IntentRouter.ZapRequest(offset: request.offset ?? 1)
            }
            response.ok = true
            response.channel = request.command == .play ? request.channel : router.nowPlayingChannelName
        } else {
            response.error = "yetkisiz"
        }
        var data = (try? JSONEncoder().encode(response)) ?? Data()
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
