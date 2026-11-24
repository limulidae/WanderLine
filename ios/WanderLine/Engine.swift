// 目前的假位置、沿路線走、背景保持執行
import CoreLocation
import Foundation

enum WalkMode: String, CaseIterable, Identifiable {
    case once, loop, back
    var id: String { rawValue }
    var label: String {
        switch self {
        case .once: return "走一次"
        case .loop: return "繞圈"
        case .back: return "來回"
        }
    }
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var position: CLLocationCoordinate2D?
    @Published private(set) var walking = false
    @Published var paused = false
    @Published private(set) var doneMeters: Double = 0
    @Published private(set) var totalMeters: Double = 0
    @Published private(set) var lap = 0
    @Published private(set) var finished = false
    @Published var lastError: String?
    @Published private(set) var busy = false

    private var walkTask: Task<Void, Never>?
    private var resendTask: Task<Void, Never>?
    private var keepAlive: KeepAlive { KeepAlive.shared }

    /// 瞬間移到某個點
    func teleport(to c: CLLocationCoordinate2D) async {
        stopWalk()
        await send(c)
        startResending()
    }

    /// 方向鍵式的小步移動
    func nudge(northMeters: Double, eastMeters: Double) async {
        guard let p = position else { return }
        stopWalk()
        let lat = p.latitude + northMeters / 111_320
        let lng = p.longitude + eastMeters / (111_320 * cos(p.latitude * .pi / 180))
        await send(CLLocationCoordinate2D(latitude: lat, longitude: lng))
        startResending()
    }

    func restore() async {
        stopWalk()
        resendTask?.cancel(); resendTask = nil
        do {
            try await DeviceLink.shared.clear()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        position = nil
        finished = false
        keepAlive.stop(for: .walk)
    }

    func startWalk(path: [CLLocationCoordinate2D], kmh: Double, mode: WalkMode, wobble: Bool) {
        guard path.count >= 2 else { return }
        stopWalk()
        resendTask?.cancel(); resendTask = nil
        finished = false
        walking = true
        paused = false
        keepAlive.start(for: .walk)
        let speed = max(0.5, kmh) / 3.6
        walkTask = Task { [weak self] in
            await self?.runWalk(path: path, speed: speed, mode: mode, wobble: wobble)
        }
    }

    func stopWalk() {
        walkTask?.cancel()
        walkTask = nil
        walking = false
        paused = false
    }

    // MARK: - 內部

    private func send(_ c: CLLocationCoordinate2D) async {
        busy = true
        defer { busy = false }
        do {
            try await DeviceLink.shared.set(c.latitude, c.longitude)
            position = c
            lastError = nil
            keepAlive.start(for: .walk)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 停在原地時每 4 秒再送一次，連線斷掉會自動重連
    private func startResending() {
        resendTask?.cancel()
        resendTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled, let p = self.position, !self.walking else { continue }
                try? await DeviceLink.shared.set(p.latitude, p.longitude)
            }
        }
    }

    private func runWalk(path: [CLLocationCoordinate2D], speed: Double, mode: WalkMode, wobble: Bool) async {
        var seq = path
        if mode == .loop, Geo.distance(path.first!, path.last!) > 1 { seq.append(path.first!) }
        lap = 0
        while !Task.isCancelled {
            let legs = zip(seq, seq.dropFirst()).map { Geo.distance($0, $1) }
            totalMeters = legs.reduce(0, +)
            doneMeters = 0
            var i = 0
            var into = 0.0
            while !Task.isCancelled {
                while i < legs.count && into >= legs[i] { into -= legs[i]; i += 1 }
                var pos = i >= legs.count ? seq.last! : Geo.lerp(seq[i], seq[i + 1], legs[i] > 0 ? into / legs[i] : 1)
                if wobble && i < legs.count {
                    // 人走路不會剛好壓在線上：左右晃一點點
                    let j = 1.5
                    pos.latitude += Double.random(in: -j...j) / 111_320
                    pos.longitude += Double.random(in: -j...j) / (111_320 * cos(pos.latitude * .pi / 180))
                }
                await send(pos)
                if i >= legs.count { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                while paused && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if let p = position { try? await DeviceLink.shared.set(p.latitude, p.longitude) }
                }
                let step = speed * Double.random(in: 0.9...1.1)
                into += step
                doneMeters = min(totalMeters, doneMeters + step)
            }
            if Task.isCancelled { return }
            lap += 1
            if mode == .once { break }
            if mode == .back { seq.reverse() }
        }
        walking = false
        finished = true
        doneMeters = totalMeters
        startResending()
    }
}

enum Geo {
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func lerp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    static func length(_ path: [CLLocationCoordinate2D]) -> Double {
        zip(path, path.dropFirst()).map { distance($0, $1) }.reduce(0, +)
    }

    static func text(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f 公里", m / 1000) : "\(Int(m.rounded())) 公尺"
    }
}

/// 切到背景時 App 會被暫停，改位置的連線就斷了：開著背景定位讓 App 繼續跑。
/// 改位置和配對（要切到「設定」）都會用到，兩邊都不需要了才關。
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    enum Reason { case walk, pairing }

    static let shared = KeepAlive()

    private let manager = CLLocationManager()
    private var reasons: Set<Reason> = []

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start(for reason: Reason) {
        let wasRunning = !reasons.isEmpty
        reasons.insert(reason)
        guard !wasRunning else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestAlwaysAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop(for reason: Reason) {
        reasons.remove(reason)
        if reasons.isEmpty { manager.stopUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
