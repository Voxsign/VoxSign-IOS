//
//  ConnectivityService.swift
//  VoxSign
//
//  T2 Connection-Aware Client layer:
//  ---------------------------------------------------------------
//  The client no longer "blindly reconnects"; it observes three connection states and drives
//  the UI and the queue:
//    unknown      -> initial state on launch; probe immediately
//    online       -> service reachable (/v1/status heartbeat passes)
//    offline      -> network down / service unreachable (voice commands go to the offline queue, not lost)
//    reconnecting -> path restored but heartbeat not yet passed (brief transition; UI shows "Reconnecting…")
//
//  Three independent triggers:
//    1. NWPathMonitor    network path change (Wi-Fi/cellular/airplane mode) -> re-probe immediately
//    2. Heartbeat timer  GET /v1/status every 30s (slow self-heal; comes online after a server restart)
//    3. Active probe     probe() before submit/flush; only go online when reachable
//
//  Cooperation with DeliveryQueue (voice never lost offline):
//    on offline, submit -> enqueue directly (no 15s timeout wait); on returning to online -> flushQueue.
//
//  User-visible effect:
//    - Top status pill: green=connected, gray=offline-queued, yellow=reconnecting, never covering the chat
//    - No more "freeze" on network loss: probe before submit; on offline show "added to offline queue" immediately
//    - Auto-recovery on network switch: Wi-Fi->cellular / airplane->restore, auto-flush within seconds
//

import Foundation
import Network
import Combine

/// Connection state (three states + one transition).
enum ConnectionState: Equatable {
    case unknown       // initial: not probed yet
    case online        // service reachable
    case offline       // service unreachable (network down / server not up)
    case reconnecting  // path restored, heartbeat not yet passed
}

/// Connection-aware service (singleton). Publishes connectionState + reachability callbacks.
final class ConnectivityService: ObservableObject {
    static let shared = ConnectivityService()

    /// Current connection state (shared by the top pill and submit/flush decisions).
    @Published private(set) var state: ConnectionState = .unknown

    /// Last probe error description (for troubleshooting in Settings).
    @Published private(set) var lastError: String = ""

    /// UI v3: latency of the last successful probe (ms), shown in the Settings connection row.
    @Published private(set) var latencyMs: Int = 0

    // Probe parameters (tune as needed after on-device testing).
    private let heartbeatInterval: TimeInterval = 30
    private let probeTimeout: TimeInterval = 5

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "vhs.connectivity.monitor")
    private var heartbeatTimer: Timer?
    private var isProbing = false

    private init() {
        // 1) Network path monitor: path change -> re-probe immediately (no waiting for the 30s heartbeat).
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if path.status == .satisfied {
                    // Path restored: if not online, enter reconnecting and probe immediately.
                    if self.state != .online {
                        self.setState(.reconnecting)
                        self.probe()
                    }
                } else {
                    // Path lost: go straight to offline (don't wait for the heartbeat).
                    self.setState(.offline)
                    self.lastError = "Network path unavailable (Wi-Fi/cellular down)"
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)

        // 2) Heartbeat timer: periodic probe (auto-detects a server restart within 30s).
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.probe()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    /// Start probing (called once onAppear; drives initial unknown -> online/offline).
    func start() {
        probe()
    }

    /// Reset probing after a server/machine-code change: clear old state and error, return to unknown, re-probe.
    func reset() {
        lastError = ""
        latencyMs = 0
        setState(.unknown)
        probe()
    }

    /// Probe: GET /v1/status, 5s timeout. Success -> online; failure -> offline (and record the error).
    /// UI v3: on success record latency in ms (Settings shows "Latency Xms").
    func probe() {
        guard !isProbing else { return }
        isProbing = true
        let started = Date()
        Task {
            defer { isProbing = false }
            do {
                _ = try await withThrowingTaskGroup(of: StatusResponse.self) { group in
                    group.addTask { try await APIClient.shared.status() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(self.probeTimeout * 1_000_000_000))
                        throw APIError.transport("Heartbeat timeout (\(Int(self.probeTimeout))s)")
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                let latency = Int(Date().timeIntervalSince(started) * 1000)
                await MainActor.run {
                    self.setState(.online)
                    self.lastError = ""
                    self.latencyMs = latency
                }
            } catch {
                await MainActor.run {
                    self.setState(.offline)
                    self.lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// Active reachability check before submit/flush: confirm online before using the network (avoid a 15s wait).
    /// - Returns: true=reachable, false=unreachable (caller should enqueue or notify).
    func isReachable() async -> Bool {
        // Cached online -> pass through (heartbeat verified within 30s; saves a round-trip).
        if state == .online { return true }
        // Not online: probe once more before deciding.
        probe()
        return state == .online
    }

    /// Network-recovery callback (AppModel subscribes: on recovery -> flushQueue).
    func onOnline(_ action: @escaping () -> Void) -> AnyCancellable {
        $state
            .filter { $0 == .online }
            .dropFirst()          // skip the initial online at launch (AppModel decides when to flush)
            .sink { _ in action() }
    }

    private func setState(_ s: ConnectionState) {
        if state != s {
            DiagLogger.shared.log("CONN", "state \(state) -> \(s)")
        }
        state = s
    }
}
