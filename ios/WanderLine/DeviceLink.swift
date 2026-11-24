// 用 idevice 從 iPhone 連回自己，開 DVT 的 LocationSimulation 改位置。
// 兩條路，都經過本機 VPN（10.7.0.1）連回手機自己：
//  1. 電腦配對檔（lockdown，像 LocationLab 的 LL Pair）→ lockdownd（62078 埠，4G 也開著）→ CoreDeviceProxy 建通道。優先用。
//  2. 手機上配對的 RPPairing 配對檔 → 「遠端配對」服務（只開在 Wi-Fi 上）建通道。
// 之後一樣：沒掛開發者映像檔就自動掛 → RemoteServer → LocationSimulation
import Foundation
import Network
import Security
import IDevice

struct LinkError: LocalizedError {
    let step: String
    let detail: String
    var errorDescription: String? { "\(step)：\(detail)" }
}

/// 所有 idevice 呼叫都在同一條序列佇列上（它的 handle 不能跨執行緒同時用）
final class DeviceLink {
    static let shared = DeviceLink()
    static let targetIP = "10.7.0.1"

    private let queue = DispatchQueue(label: "wanderline.link", qos: .userInitiated)
    private var provider: OpaquePointer?   // 走電腦配對檔時的 lockdown 連線
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var sim: OpaquePointer?

    private init() {
        _ = idevice_init_logger(Info, Disabled, nil)
    }

    func set(_ lat: Double, _ lng: Double) async throws {
        // 已經連著就直接送
        let sent = try await run { () -> Bool in
            guard let sim = self.sim else { return false }
            return self.check(location_simulation_set(sim, lat, lng)) == nil
        }
        if sent { return }

        try await prepare()
        try await run {
            self.drop()
            try self.connect()
            if let e = self.check(location_simulation_set(self.sim, lat, lng)) {
                self.drop()
                throw LinkError(step: "改位置失敗", detail: e)
            }
        }
    }

    func clear() async throws {
        try await run {
            guard let sim = self.sim else { return }
            let e = self.check(location_simulation_clear(sim))
            self.drop()
            if let e { throw LinkError(step: "還原失敗", detail: e) }
        }
    }

    func disconnect() async {
        try? await run { self.drop() }
    }

    /// 只測連線（設定頁「測試連線」用）：會順便開 VPN、下載並掛上開發者映像檔
    func test() async throws {
        try await prepare()
        try await run {
            self.drop()
            try self.connect()
        }
    }

    // MARK: - 內部

    /// 需要等使用者或網路的準備工作（不在 idevice 佇列上做）
    private func prepare() async throws {
        guard PairingStore.exists || LockdownStore.exists else {
            throw LinkError(step: "還沒配對", detail: "到「設定」按「開始配對」，或匯入電腦配對檔")
        }
        try await LoopbackVPN.shared.ensureOn()
        if !DiskImage.ready {
            do { try await DiskImage.download() } catch let e as LinkError { throw e } catch {
                throw LinkError(step: "開發者映像檔下載失敗", detail: "要有網路（\(error.localizedDescription)）")
            }
        }
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            queue.async {
                do { c.resume(returning: try body()) } catch { c.resume(throwing: error) }
            }
        }
    }

    /// 錯誤轉成文字並釋放
    private func check(_ err: UnsafeMutablePointer<IdeviceFfiError>?) -> String? {
        guard let err else { return nil }
        let msg = err.pointee.message.map { String(cString: $0) } ?? "未知錯誤"
        let text = "\(msg)（\(err.pointee.code)）"
        idevice_error_free(err)
        return text
    }

    private func drop() {
        // sim 借用 server，所以先放 sim
        if let sim { location_simulation_free(sim) }
        if let server { remote_server_free(server) }
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        if let provider { idevice_provider_free(provider) }
        sim = nil; server = nil; handshake = nil; adapter = nil; provider = nil
    }

    /// Wi-Fi（en0）有沒有 IPv4 位址
    static func wifiUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            if String(cString: i.pointee.ifa_name) == "en0", let a = i.pointee.ifa_addr,
               a.pointee.sa_family == sa_family_t(AF_INET), (i.pointee.ifa_flags & UInt32(IFF_UP)) != 0 {
                return true
            }
            p = i.pointee.ifa_next
        }
        return false
    }

    private func connect() throws {
        var lockdownError: LinkError?
        if let data = LockdownStore.load() {
            do { try openViaLockdown(data) } catch let e as LinkError { lockdownError = e; drop() }
        }
        if adapter == nil {
            guard PairingStore.exists else {
                throw lockdownError ?? LinkError(step: "還沒配對", detail: "到「設定」按「開始配對」")
            }
            do { try openViaRPPairing() } catch let e as LinkError {
                // 兩條都失敗：電腦配對檔的錯誤比較有參考價值（它在 4G 也該通）
                if let l = lockdownError { throw LinkError(step: l.step, detail: "\(l.detail)；手機配對也失敗：\(e.step)") }
                throw e
            }
        }

        try ensureMounted()

        if let e = check(remote_server_connect_rsd(adapter, handshake, &server)) {
            drop()
            throw LinkError(step: "開發者服務打不開（「開發者模式」有打開嗎？）", detail: e)
        }
        if let e = check(location_simulation_new(server, &sim)) {
            drop()
            throw LinkError(step: "改位置服務打不開", detail: e)
        }
    }

    /// 電腦配對檔：lockdownd（62078）→ CoreDeviceProxy → 軟體通道。4G 也能用。
    private func openViaLockdown(_ data: Data) throws {
        var pf: OpaquePointer?
        let parseErr = data.withUnsafeBytes { raw in
            idevice_pairing_file_from_bytes(raw.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &pf)
        }
        if let e = check(parseErr) { throw LinkError(step: "電腦配對檔讀不懂，請重新產生", detail: e) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(62078).bigEndian
        _ = DeviceLink.targetIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        var newProvider: OpaquePointer?
        // pf 交給 provider，之後不能再用
        let provErr = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                idevice_tcp_provider_new(sa, pf, "WanderLine", &newProvider)
            }
        }
        if let e = check(provErr) { throw LinkError(step: "電腦配對檔無法使用", detail: e) }
        provider = newProvider

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let tunnelErr = tunnel_create_usb(provider, &newAdapter, &newHandshake)
        adapter = newAdapter
        handshake = newHandshake
        if let e = check(tunnelErr) {
            throw LinkError(step: "用電腦配對檔連不上（手機有解鎖嗎？手機重設或更新後要重新產生配對檔）", detail: e)
        }
    }

    /// 手機上配對的 RPPairing 配對檔：「遠端配對」服務 → 通道。要有 Wi-Fi。
    private func openViaRPPairing() throws {
        guard let data = PairingStore.load() else {
            throw LinkError(step: "還沒配對", detail: "到「設定」按「開始配對」")
        }
        var pairing: OpaquePointer?
        let parseErr = data.withUnsafeBytes { raw in
            rp_pairing_file_from_bytes(raw.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &pairing)
        }
        if let e = check(parseErr) { throw LinkError(step: "配對檔讀不懂，請重新配對", detail: e) }
        defer { rp_pairing_file_free(pairing) }

        // 依序試：Bonjour 找到的遠端配對埠 → RSD 固定埠 58783（不用 Bonjour，4G 時靠這個）→ 常見的預設埠
        let found = PairingPort.resolve()
        var tries: [(UInt16, Bool)] = []          // (埠, 是不是 RemoteXPC/RSD)
        if let found { tries.append((found, false)) }
        tries.append((58783, true))
        if found == nil { tries.append((PairingPort.fallback, false)) }

        var errors: [String] = []
        for (port, viaRSD) in tries {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            _ = DeviceLink.targetIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

            var newAdapter: OpaquePointer?
            var newHandshake: OpaquePointer?
            let tunnelErr = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    viaRSD
                        ? tunnel_create_remotexpc(sa, socklen_t(MemoryLayout<sockaddr_in>.size), "WanderLine", pairing, nil, nil, &newAdapter, &newHandshake)
                        : tunnel_create_rppairing(sa, socklen_t(MemoryLayout<sockaddr_in>.size), "WanderLine", pairing, nil, nil, &newAdapter, &newHandshake)
                }
            }
            adapter = newAdapter
            handshake = newHandshake
            guard let e = check(tunnelErr) else { return }
            drop()
            errors.append("埠 \(port)\(viaRSD ? "（RSD）" : "")：\(e)")
        }
        let wifi = DeviceLink.wifiUp() ? "有 Wi-Fi" : "沒有 Wi-Fi"
        let bonjour = found == nil ? "找不到配對服務的埠" : "配對服務在埠 \(found!)"
        throw LinkError(step: "連不上手機自己（手機有解鎖嗎？配對過期的話請重新配對）",
                        detail: "\(wifi)、\(bonjour)。" + errors.joined(separator: "；"))
    }

    /// 開發者映像檔沒掛上就掛（手機重開機後會掉）
    private func ensureMounted() throws {
        if DiskImage.useCryptex {
            var installed: UnsafeMutablePointer<InstalledCryptexC>?
            if check(cryptexd_installed_ddi(adapter, handshake, &installed)) == nil {
                let has = installed != nil
                cryptexd_free_installed_cryptex(installed)
                if has { return }
                var assets: OpaquePointer?
                if let e = check(cryptex1_assets_load(DiskImage.dir.path, &assets)) {
                    DiskImage.reset()
                    drop(); throw LinkError(step: "開發者映像檔壞了，下次會重新下載", detail: e)
                }
                defer { cryptex1_assets_free(assets) }
                if let e = check(cryptexd_install_ddi(adapter, handshake, assets, nil)) {
                    drop(); throw LinkError(step: "開發者映像檔掛不上（要有網路，蘋果要簽名）", detail: e)
                }
                return
            }
            // 查不到 cryptex 狀態時，改用舊的方式檢查
        }

        var mounter: OpaquePointer?
        if let e = check(image_mounter_connect_rsd(adapter, handshake, &mounter)) {
            drop(); throw LinkError(step: "連不上映像檔服務", detail: e)
        }
        defer { image_mounter_free(mounter) }

        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        if check(image_mounter_copy_devices(mounter, &devices, &count)) == nil, let devices {
            for i in 0..<count { plist_free(devices[i]) }
            idevice_data_free(UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                              UInt(count * MemoryLayout<plist_t?>.stride))
            if count > 0 { return }
        }
        try mountPersonalized(mounter)
    }

    private func mountPersonalized(_ mounter: OpaquePointer?) throws {
        let d = DiskImage.dir
        guard let image = try? Data(contentsOf: d.appendingPathComponent("Image.dmg"), options: .mappedIfSafe),
              let trust = try? Data(contentsOf: d.appendingPathComponent("Image.dmg.trustcache")),
              let manifest = try? Data(contentsOf: d.appendingPathComponent("BuildManifest.plist")) else {
            DiskImage.reset()
            drop(); throw LinkError(step: "開發者映像檔不見了", detail: "下次連線會重新下載")
        }

        // 要先問晶片 ID 才能請蘋果簽名
        var lockdown: OpaquePointer?
        if let e = check(lockdownd_connect_rsd(adapter, handshake, &lockdown)) {
            drop(); throw LinkError(step: "讀不到手機資訊", detail: e)
        }
        var chipPlist: plist_t?
        let chipErr = check(lockdownd_get_value(lockdown, "UniqueChipID", nil, &chipPlist))
        lockdownd_client_free(lockdown)
        var chipID: UInt64 = 0
        if let chipPlist { plist_get_uint_val(chipPlist, &chipID); plist_free(chipPlist) }
        if chipErr != nil || chipID == 0 {
            drop(); throw LinkError(step: "讀不到手機晶片 ID", detail: chipErr ?? "空的")
        }

        let err = image.withUnsafeBytes { i in
            trust.withUnsafeBytes { t in
                manifest.withUnsafeBytes { m in
                    image_mounter_mount_personalized_rsd(
                        mounter, adapter, handshake,
                        i.bindMemory(to: UInt8.self).baseAddress, image.count,
                        t.bindMemory(to: UInt8.self).baseAddress, trust.count,
                        m.bindMemory(to: UInt8.self).baseAddress, manifest.count,
                        nil, chipID)
                }
            }
        }
        if let e = check(err) {
            drop(); throw LinkError(step: "開發者映像檔掛不上（要有網路，蘋果要簽名）", detail: e)
        }
    }
}

/// 找手機自己的 _remotepairing._tcp 服務埠（優先用 loopback 介面上的那個）
enum PairingPort {
    static let fallback: UInt16 = 49152

    private final class State {
        var done = false
        var port: UInt16?
        var conn: NWConnection?
        var loopback = false
    }

    /// 找不到（例如沒有 Wi-Fi 時 Bonjour 不通）回傳 nil
    static func resolve(timeout: TimeInterval = 5) -> UInt16? {
        let q = DispatchQueue(label: "wanderline.port")
        let sem = DispatchSemaphore(value: 0)
        let s = State()
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: params)

        let finish = {
            guard !s.done else { return }
            s.done = true
            browser.cancel()
            s.conn?.cancel()
            sem.signal()
        }

        browser.browseResultsChangedHandler = { results, _ in
            guard !s.done else { return }
            let items = results.compactMap { r -> (NWEndpoint, Bool)? in
                guard case .service = r.endpoint else { return nil }
                return (r.endpoint, r.interfaces.contains { $0.name.hasPrefix("lo") })
            }
            guard let pick = items.first(where: { $0.1 }) ?? items.first else { return }
            if s.conn != nil && (s.loopback || !pick.1) { return }
            s.loopback = pick.1
            s.conn?.cancel()
            let c = NWConnection(to: pick.0, using: params)
            s.conn = c
            c.stateUpdateHandler = { state in
                guard !s.done else { return }
                switch state {
                case .ready, .waiting:
                    if case .hostPort(_, let p)? = c.currentPath?.remoteEndpoint, p.rawValue != 0 {
                        s.port = p.rawValue
                        finish()
                    }
                default:
                    break
                }
            }
            c.start(queue: q)
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { finish() }
        }
        browser.start(queue: q)
        _ = sem.wait(timeout: .now() + timeout)
        return q.sync { () -> UInt16? in
            finish()
            return s.port
        }
    }
}

/// RPPairing 配對檔存在 App 的「文件」資料夾
/// 配對檔：存在 App 的 Documents，另外備份一份到鑰匙圈。
/// 鑰匙圈在 App 被刪掉重裝後還在，所以重裝也不用重新配對。
enum PairingStore {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var url: URL { docs.appendingPathComponent("rppairing.plist") }

    static func load() -> Data? {
        if let d = try? Data(contentsOf: url) {
            if Keychain.read(account) == nil { Keychain.write(d, account) }   // 舊版存的，補一份到鑰匙圈
            return d
        }
        if let d = Keychain.read(account) {                               // 重裝後：從鑰匙圈拿回來
            try? d.write(to: url, options: .atomic)
            return d
        }
        return nil
    }
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) || Keychain.read(account) != nil }
    private static let account = "rppairing"

    /// 先用 idevice 讀一次，確定是 RPPairing 配對檔才存
    static func save(_ data: Data) throws {
        var handle: OpaquePointer?
        let err = data.withUnsafeBytes { raw in
            rp_pairing_file_from_bytes(raw.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &handle)
        }
        if let err {
            let msg = err.pointee.message.map { String(cString: $0) } ?? ""
            idevice_error_free(err)
            throw LinkError(step: "這不是 RPPairing 配對檔", detail: msg)
        }
        rp_pairing_file_free(handle)
        try data.write(to: url, options: .atomic)
        Keychain.write(data, account)
    }

    /// 匯入：手機配對的 RPPairing 檔，或 Mac 產生的電腦配對檔（lockdown），自動判斷
    @discardableResult
    static func save(from source: URL) throws -> String {
        let ok = source.startAccessingSecurityScopedResource()
        defer { if ok { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        if (try? save(data)) != nil { return "已匯入手機配對檔" }
        try LockdownStore.save(data)
        return "已匯入電腦配對檔：之後 4G 也能改位置"
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
        Keychain.delete(account)
    }

}

/// Mac 產生的電腦配對檔（lockdown 的 pair record，像 LL Pair 做的那種）。走這個 4G 也能用。
enum LockdownStore {
    static var url: URL { PairingStore.docs.appendingPathComponent("lockdown.plist") }
    private static let account = "lockdown"

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) || Keychain.read(account) != nil }

    static func load() -> Data? {
        if let d = try? Data(contentsOf: url) { return d }
        if let d = Keychain.read(account) { try? d.write(to: url, options: .atomic); return d }
        return nil
    }

    /// 先用 idevice 讀一次，確定是電腦配對檔才存
    static func save(_ data: Data) throws {
        var handle: OpaquePointer?
        let err = data.withUnsafeBytes { raw in
            idevice_pairing_file_from_bytes(raw.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &handle)
        }
        if let err {
            let msg = err.pointee.message.map { String(cString: $0) } ?? ""
            idevice_error_free(err)
            throw LinkError(step: "看不懂這個檔案（不是配對檔）", detail: msg)
        }
        idevice_pairing_file_free(handle)
        try data.write(to: url, options: .atomic)
        Keychain.write(data, account)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
        Keychain.delete(account)
    }
}

/// 鑰匙圈：只存在這支手機（不跟 iCloud 同步），App 刪掉重裝後還在；開機解鎖一次後背景也讀得到
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "wang.chunchieh.wanderline.pairing",
         kSecAttrAccount as String: account]
    }
    static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func write(_ data: Data, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
