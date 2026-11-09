#if os(iOS)
import Combine
import Foundation
import Network

/// Discovery lists nearby servers. Connections use the scanned or entered LAN
/// address, independently of the comic-source networking configuration.
@MainActor
final class LanSRDiscovery: ObservableObject {
    @Published private(set) var names: [String] = []
    @Published private(set) var message = ""
    @Published private(set) var isSearching = false
    private var browser: NWBrowser?
    private var generation = UUID()

    func start() {
        stop()
        let generation = UUID()
        self.generation = generation
        names = []
        message = "正在发现附近电脑…"
        isSearching = true
        let browser = NWBrowser(for: .bonjour(type: "_picax-sr._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = Set(results.compactMap { result -> String? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return String(name.prefix(128))
            }).sorted()
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.names = names
                self.message = names.isEmpty ? "暂未发现电脑；仍可直接扫码或粘贴连接信息。" : "发现电脑后，扫描电脑二维码或输入地址即可连接。"
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let failure: String?
            switch state {
            case .failed(let error), .waiting(let error): failure = error.localizedDescription
            default: failure = nil
            }
            guard let failure else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.message = "发现不可用：\(failure)。可检查系统“本地网络”权限或直接扫码。"
            }
        }
        browser.start(queue: DispatchQueue(label: "moye.PicaX.lan-discovery"))
    }

    func stop() {
        generation = UUID()
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}
#endif
