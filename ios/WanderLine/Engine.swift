// 目前的假位置、沿路線走、背景保持執行
import CoreLocation
import Foundation

enum WalkMode: String, CaseIterable, Identifiable {
    case once, loop, back
    var id: String { rawValue }
    var label: String {
        switch self {
        case .once: return "停止"
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
    @Published var paused = false {
        didSet { if walking { progress.paused = paused; saveProgress() } }
    }
    @Published private(set) var route: [CLLocationCoordinate2D] = []   // 正在走的整條路線
    @Published private(set) var routeName: String?
    @Published private(set) var doneMeters: Double = 0
    @Published private(set) var totalMeters: Double = 0
    @Published private(set) var lap = 0
    @Published private(set) var finished = false
    @Published var lastError: String?
    @Published private(set) var busy = false

    private var walkTask: Task<Void, Never>?
    private var resendTask: Task<Void, Never>?
    private var keepAlive: KeepAlive { KeepAlive.shared }

    // MARK: 關掉 App 再打開要接著走：開始走時存路線，之後每秒存走到哪裡
    private struct Progress: Codable {
        var kmh: Double
        var mode: String
        var wobble: Bool
        var name: String?
        var lap = 0
        var reversed = false      // 「來回」走到回程了
        var done = 0.0            // 這一圈走了幾公尺
        var paused = false
    }
    private enum Saved {
        static let path = "walk.path"
        static let progress = "walk.progress"
        static let parked = "walk.parked"     // 沒在走、停在某個假位置
    }
    private var progress = Progress(kmh: 4.5, mode: WalkMode.once.rawValue, wobble: true)

    private func saveProgress() {
        UserDefaults.standard.set(try? JSONEncoder().encode(progress), forKey: Saved.progress)
    }

    private func park(_ c: CLLocationCoordinate2D?) {
        if let c { UserDefaults.standard.set([c.latitude, c.longitude], forKey: Saved.parked) }
        else { UserDefaults.standard.removeObject(forKey: Saved.parked) }
    }

    /// App 打開時：上次走到一半就從那裡接著走；停在某個假位置就繼續停在那裡
    func resumeIfNeeded() async {
        guard !walking, position == nil else { return }
        let d = UserDefaults.standard
        if let pd = d.data(forKey: Saved.path), let pts = try? JSONDecoder().decode([[Double]].self, from: pd),
           let gd = d.data(forKey: Saved.progress), let p = try? JSONDecoder().decode(Progress.self, from: gd) {
            let path = pts.filter { $0.count == 2 }.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            if path.count >= 2 {
                begin(path: path, from: p)
                return
            }
        }
        if let c = d.array(forKey: Saved.parked) as? [Double], c.count == 2 {
            await send(CLLocationCoordinate2D(latitude: c[0], longitude: c[1]))
            startResending()
        }
    }

    /// 瞬間移到某個點
    func teleport(to c: CLLocationCoordinate2D) async {
        stopWalk()
        await send(c)
        if position != nil { park(position) }
        startResending()
    }

    /// 方向鍵式的小步移動
    func nudge(northMeters: Double, eastMeters: Double) async {
        guard let p = position else { return }
        stopWalk()
        let lat = p.latitude + northMeters / 111_320
        let lng = p.longitude + eastMeters / (111_320 * cos(p.latitude * .pi / 180))
        await send(CLLocationCoordinate2D(latitude: lat, longitude: lng))
        park(position)
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
        park(nil)
        finished = false
        keepAlive.stop(for: .walk)
    }

    func startWalk(path: [CLLocationCoordinate2D], kmh: Double, mode: WalkMode, wobble: Bool, name: String? = nil) {
        begin(path: path, from: Progress(kmh: kmh, mode: mode.rawValue, wobble: wobble, name: name))
    }

    private func begin(path: [CLLocationCoordinate2D], from p: Progress) {
        guard path.count >= 2 else { return }
        stopWalk()
        resendTask?.cancel(); resendTask = nil
        finished = false
        route = path
        routeName = p.name
        progress = p
        walking = true
        paused = p.paused
        park(nil)
        UserDefaults.standard.set(try? JSONEncoder().encode(path.map { [$0.latitude, $0.longitude] }), forKey: Saved.path)
        saveProgress()
        keepAlive.start(for: .walk)
        walkTask = Task { [weak self] in
            await self?.runWalk(path: path, from: p)
        }
    }

    /// 停止走路（停在現在的位置）；下次打開 App 不會再接著走
    func stopWalk() {
        walkTask?.cancel()
        walkTask = nil
        walking = false
        paused = false
        UserDefaults.standard.removeObject(forKey: Saved.path)
        UserDefaults.standard.removeObject(forKey: Saved.progress)
        if position != nil { park(position) }
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

    private func runWalk(path: [CLLocationCoordinate2D], from start: Progress) async {
        let mode = WalkMode(rawValue: start.mode) ?? .once
        let speed = max(0.5, start.kmh) / 3.6
        let wobble = start.wobble
        var seq = path
        if mode == .loop, Geo.distance(path.first!, path.last!) > 1 { seq.append(path.first!) }
        var reversed = start.reversed
        if reversed { seq.reverse() }
        lap = start.lap
        var resumeAt = start.done       // 接著上次走：第一圈從上次走到的地方開始
        while !Task.isCancelled {
            let legs = zip(seq, seq.dropFirst()).map { Geo.distance($0, $1) }
            totalMeters = legs.reduce(0, +)
            var into = min(resumeAt, totalMeters)
            doneMeters = into
            resumeAt = 0
            var i = 0
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
                progress.lap = lap
                progress.reversed = reversed
                progress.done = doneMeters
                saveProgress()
            }
            if Task.isCancelled { return }
            lap += 1
            if mode == .once { break }
            if mode == .back { seq.reverse(); reversed.toggle() }
            progress.lap = lap
            progress.reversed = reversed
            progress.done = 0
            saveProgress()
        }
        if Task.isCancelled { return }
        walking = false
        finished = true
        doneMeters = totalMeters
        // 走完了：下次打開停在終點，不會再走一次
        UserDefaults.standard.removeObject(forKey: Saved.path)
        UserDefaults.standard.removeObject(forKey: Saved.progress)
        park(position)
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
