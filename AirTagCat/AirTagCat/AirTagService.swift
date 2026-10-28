import Foundation
import Combine

// Talks to the Frida daemon running on localhost:8765.
// Start the daemon first: python3 controller.py --server
@MainActor
final class AirTagService: ObservableObject {

    @Published var rssi: Int?       = nil
    @Published var distance: Double? = nil
    @Published var daemonReady: Bool = false

    private let base = "http://127.0.0.1:8765"
    private var timer: AnyCancellable?

    // ── Path-loss model ───────────────────────────────────────────────────────
    // Tune rssi1m: stand exactly 1 m from the tag, note the reported RSSI.
    private let rssi1m: Double = -59   // dBm at 1 m (calibrate once)
    private let n:      Double =  2.7  // path-loss exponent (2.0 = open air)

    private func toMeters(_ rssi: Int) -> Double {
        pow(10.0, (rssi1m - Double(rssi)) / (10.0 * n))
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    func startPolling() {
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in Task { await self?.tick() } }
        Task { await tick() }
    }

    private func tick() async {
        await checkStatus()
        if daemonReady { await fetchRSSI() }
    }

    // ── Endpoints ─────────────────────────────────────────────────────────────
    private func checkStatus() async {
        guard let url = URL(string: "\(base)/status") else { return }
        do {
            let (data, _) = try await session().data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            daemonReady = (json?["ready"] as? Bool) == true
        } catch {
            daemonReady = false
            rssi = nil; distance = nil
        }
    }

    private func fetchRSSI() async {
        guard let url = URL(string: "\(base)/rssi") else { return }
        do {
            let (data, _) = try await session().data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let r = json?["rssi"] as? Int {
                rssi = r
                distance = toMeters(r)
            }
        } catch {}
    }

    func playSound() async {
        await post("/play")
    }

    func stopSound() async {
        await post("/stop")
    }

    private func post(_ path: String) async {
        guard let url = URL(string: "\(base)\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        try? await session().data(for: req)
    }

    // Short timeout so the UI stays responsive if the daemon is down
    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        return URLSession(configuration: cfg)
    }
}
