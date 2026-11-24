// 用 idevice 從 iPhone 連回自己，開 DVT 的 LocationSimulation 改位置。
// 路徑：本機 VPN（10.7.0.1）連回手機自己 → 手機上配對的 RPPairing 配對檔建立開發者通道
// → 沒掛開發者映像檔就自動掛 → RemoteServer → LocationSimulation。全程不用電腦。
import Foundation
import Network
import Security
import IDevice

/// 給使用者看的錯誤：title 發生什麼事、todo 該怎麼做（都用白話）；tech 是技術細節，畫面上不顯示，
/// 長按錯誤訊息可以複製（回報問題用）
struct LinkError: LocalizedError {
    let title: String
    var todo: String? = nil
    var tech: String? = nil
    var errorDescription: String? { todo.map { "\(title)\n\($0)" } ?? title }

    /// 最近一次錯誤的技術細節
    nonisolated(unsafe) static var lastTech = ""
    init(title: String, todo: String? = nil, tech: String? = nil) {
        self.title = title; self.todo = todo; self.tech = tech
        if let tech { LinkError.lastTech = "\(title)：\(tech)"; NSLog("WanderLine: %@：%@", title, tech) }
    }
}

/// 所有 idevice 呼叫都在同一條序列佇列上（它的 handle 不能跨執行緒同時用）
final class DeviceLink {
    static let shared = DeviceLink()
    static let targetIP = "10.7.0.1"

    private let queue = DispatchQueue(label: "wanderline.link", qos: .userInitiated)
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var sim: OpaquePointer?

    private init() {
        _ = idevice_init_logger(Info, Disabled, nil)
    }

    func set(_ lat: Double, _ lng: Double) async throws {
        // 已經連著就直接送
        // 原本的連線送不出去時，記下原因（切網路後斷線時方便查）
        // 剛切網路（關飛航模式）時可能卡一下：先在原本的連線上多試兩次，不要馬上丟掉——
        // 在 4G 下丟掉就連不回來了（要再開飛航模式）
        let fastError = try await run { () -> String? in
            guard let sim = self.sim else { return "還沒連線" }
            var last: String?
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.7) }
                last = self.check(location_simulation_set(sim, lat, lng))
                if last == nil { return nil }
            }
            return last
        }
        if fastError == nil { return }

        try await prepare()
        try await run {
            self.drop()
            do { try self.connect() } catch let e as LinkError {
                throw LinkError(title: e.title, todo: e.todo, tech: (e.tech ?? "") + "；原本的連線：\(fastError ?? "")")
            }
            if let e = self.check(location_simulation_set(self.sim, lat, lng)) {
                self.drop()
                throw LinkError(title: "位置沒改成功", todo: "再按一次試試；還是不行就把 WanderLine 關掉重開", tech: e)
            }
        }
    }

    func clear() async throws {
        try await run {
            guard let sim = self.sim else { return }
            // 還原後連線留著：用 4G 時重新連線要先開飛航模式，留著下次改位置就不用再弄一次
            if let e = self.check(location_simulation_clear(sim)) {
                self.drop()
                throw LinkError(title: "沒能改回真實位置", todo: "再按一次「停止模擬」", tech: e)
            }
        }
    }

    func disconnect() async {
        try? await run { self.drop() }
    }

    /// 只測連線（設定頁「測試連線」用）：會順便開 VPN、下載並掛上開發者映像檔
    /// 已經連著就不重連：在 4G 下丟掉連線就連不回來（要再開飛航模式）
    func test() async throws {
        if try await run({ self.sim != nil }) { return }
        try await prepare()
        try await run {
            self.drop()
            try self.connect()
        }
    }

    // MARK: - 內部

    /// 需要等使用者或網路的準備工作（不在 idevice 佇列上做）
    private func prepare() async throws {
        guard PairingStore.exists else {
            throw LinkError(title: "還沒配對", todo: "到 ☰ →「設定」按「開始配對」")
        }
        try await LoopbackVPN.shared.ensureOn()
        if !DiskImage.ready {
            do { try await DiskImage.download() } catch let e as LinkError { throw e } catch {
                throw LinkError(title: "開發者映像檔下載失敗", todo: "要有網路，連上網路後再試一次", tech: error.localizedDescription)
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
        sim = nil; server = nil; handshake = nil; adapter = nil
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
        do { try openTunnel() } catch {
            DevModeStatus.report(nil)   // 連不上就不知道開發者模式現在的狀態
            throw error
        }
        try checkDeveloperMode()

        try ensureMounted()

        if let e = check(remote_server_connect_rsd(adapter, handshake, &server)) {
            drop()
            throw LinkError(title: "連不上手機的開發者服務", todo: "確認「設定 → 隱私權與安全性 → 開發者模式」是打開的，再試一次", tech: e)
        }
        if let e = check(location_simulation_new(server, &sim)) {
            drop()
            throw LinkError(title: "改位置的服務沒開起來", todo: "再試一次；還是不行就把手機重開機", tech: e)
        }
    }

    /// 直接問手機「開發者模式」是不是開著（設定頁第 1 步用），關著就停下來告訴使用者
    private func checkDeveloperMode() throws {
        var lockdown: OpaquePointer?
        guard check(lockdownd_connect_rsd(adapter, handshake, &lockdown)) == nil else { return }
        defer { lockdownd_client_free(lockdown) }
        var value: plist_t?
        guard check(lockdownd_get_value(lockdown, "DeveloperModeStatus", "com.apple.security.mac.amfi", &value)) == nil,
              let value else { return }
        var on: UInt8 = 0
        plist_get_bool_val(value, &on)
        plist_free(value)
        DevModeStatus.report(on != 0)
        if on == 0 {
            drop()
            throw LinkError(title: "開發者模式沒有打開", todo: "到「設定 → 隱私權與安全性 → 開發者模式」打開，手機會重新開機")
        }
    }

    /// 手機上配對的 RPPairing 配對檔 → 開發者通道
    private func openTunnel() throws {
        guard let data = PairingStore.load() else {
            throw LinkError(title: "還沒配對", todo: "到 ☰ →「設定」按「開始配對」")
        }
        var pairing: OpaquePointer?
        let parseErr = data.withUnsafeBytes { raw in
            rp_pairing_file_from_bytes(raw.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &pairing)
        }
        if let e = check(parseErr) { throw LinkError(title: "配對資料壞了", todo: "到 ☰ →「設定」重新配對", tech: e) }
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
        let bonjour = found == nil ? "找不到配對服務的埠" : "配對服務在埠 \(found!)"
        // 正在用 4G/5G 時，iPhone 會擋住新的開發者連線；先在飛航模式（或 Wi-Fi）連上，之後切回 4G 連線會留著
        if !DeviceLink.wifiUp() {
            throw LinkError(title: "用 4G 時連不上",
                            todo: "① 打開飛航模式\n② 再按一次「移到這裡」\n③ 位置改好後關掉飛航模式",
                            tech: bonjour + "。" + errors.joined(separator: "；"))
        }
        throw LinkError(title: "連不上",
                        todo: "確認手機已解鎖再試一次；還是不行就到 ☰ →「設定」重新配對",
                        tech: "有 Wi-Fi、" + bonjour + "。" + errors.joined(separator: "；"))
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
                    drop(); throw LinkError(title: "開發者映像檔壞了", todo: "再試一次，會自動重新下載", tech: e)
                }
                defer { cryptex1_assets_free(assets) }
                if let e = check(cryptexd_install_ddi(adapter, handshake, assets, nil)) {
                    drop(); throw LinkError(title: "開發者映像檔掛不上", todo: "要有網路（蘋果要線上確認），連上網路後再試一次", tech: e)
                }
                return
            }
            // 查不到 cryptex 狀態時，改用舊的方式檢查
        }

        var mounter: OpaquePointer?
        if let e = check(image_mounter_connect_rsd(adapter, handshake, &mounter)) {
            drop(); throw LinkError(title: "開發者映像檔服務沒回應", todo: "再試一次；還是不行就把手機重開機", tech: e)
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
            drop(); throw LinkError(title: "開發者映像檔不見了", todo: "再試一次，會自動重新下載")
        }

        // 要先問晶片 ID 才能請蘋果簽名
        var lockdown: OpaquePointer?
        if let e = check(lockdownd_connect_rsd(adapter, handshake, &lockdown)) {
            drop(); throw LinkError(title: "讀不到手機資訊", todo: "再試一次", tech: e)
        }
        var chipPlist: plist_t?
        let chipErr = check(lockdownd_get_value(lockdown, "UniqueChipID", nil, &chipPlist))
        lockdownd_client_free(lockdown)
        var chipID: UInt64 = 0
        if let chipPlist { plist_get_uint_val(chipPlist, &chipID); plist_free(chipPlist) }
        if chipErr != nil || chipID == 0 {
            drop(); throw LinkError(title: "讀不到手機資訊", todo: "再試一次", tech: "晶片 ID：" + (chipErr ?? "空的"))
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
            drop(); throw LinkError(title: "開發者映像檔掛不上", todo: "要有網路（蘋果要線上確認），連上網路後再試一次", tech: e)
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
            throw LinkError(title: "這不是 WanderLine 的配對檔", todo: "請改用「配對這支 iPhone」在手機上配對", tech: msg)
        }
        rp_pairing_file_free(handle)
        try data.write(to: url, options: .atomic)
        Keychain.write(data, account)
    }

    /// 匯入配對檔
    @discardableResult
    static func save(from source: URL) throws -> String {
        let ok = source.startAccessingSecurityScopedResource()
        defer { if ok { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        try save(data)
        return "已匯入配對檔"
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

/// 開發者模式的狀態：只能在連上手機的開發者服務時問到，問到就記下來（設定頁第 1 步顯示用）
/// nil = 還沒確認（還沒連上過，或上次連線失敗）
@MainActor
final class DevModeStatus: ObservableObject {
    static let shared = DevModeStatus()
    @Published private(set) var on: Bool? = UserDefaults.standard.object(forKey: "devModeOn") as? Bool

    nonisolated static func report(_ on: Bool?) {
        Task { @MainActor in
            shared.on = on
            if let on { UserDefaults.standard.set(on, forKey: "devModeOn") } else { UserDefaults.standard.removeObject(forKey: "devModeOn") }
        }
    }
}
