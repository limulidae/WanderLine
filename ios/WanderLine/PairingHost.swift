// 在手機上直接配對（iOS 27 以上）：WanderLine 假裝成一台「可以配對的電腦」，
// 用 Bonjour 廣播 _remotepairing-pairable-host._tcp。使用者到
// 設定 → 隱私權與安全性 → 開發者模式，點「與 WanderLine 配對」，輸入 App 顯示的 6 位數代碼，
// 手機就會把配對資料交給我們，存成 RPPairing 配對檔。整個過程不用電腦。
import Darwin
import Foundation
import IDevice
import UserNotifications

@MainActor
final class PairingHost: ObservableObject {
    static let shared = PairingHost()

    enum Phase: Equatable {
        case idle
        case waiting            // 等手機從「設定」連過來
        case pin(String)        // 請使用者在「設定」輸入這組數字
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var running: Bool {
        switch phase {
        case .waiting, .pin: return true
        default: return false
        }
    }

    private var service: NetService?
    private var listenFD: Int32 = -1
    private var session = 0

    func start() {
        guard !running else { return }
        session += 1
        let id = session
        phase = .waiting
        KeepAlive.shared.start(for: .pairing)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = PairingHost.pair { fd, name, port, records in
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { () -> Bool in
                        let host = PairingHost.shared
                        guard host.session == id else { return false }
                        host.listenFD = fd
                        host.publish(name: name, port: port, records: records)
                        return true
                    }
                }
            }
            Task { @MainActor in PairingHost.shared.finish(id, result) }
        }
    }

    func cancel() {
        session += 1
        stopListening()
        KeepAlive.shared.stop(for: .pairing)
        phase = .idle
    }

    /// 配對結果畫面看完後回到一開始
    func reset() {
        guard !running else { return }
        phase = .idle
    }

    fileprivate func showPIN(_ code: String) {
        guard running else { return }
        phase = .pin(code)
        // 使用者這時在「設定」裡，用通知把代碼送過去
        let content = UNMutableNotificationContent()
        content.title = "WanderLine 配對碼：\(code)"
        content.body = "在「設定」裡輸入這 6 位數字就完成配對"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wanderline.pin", content: content, trigger: nil))
    }

    // MARK: - 內部

    private func finish(_ id: Int, _ result: Result<Data, LinkError>) {
        guard session == id else { return }
        stopListening()
        KeepAlive.shared.stop(for: .pairing)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["wanderline.pin"])
        switch result {
        case .success(let data):
            do {
                try PairingStore.save(data)
                phase = .done
            } catch {
                phase = .failed(error.localizedDescription)
            }
        case .failure(let e):
            phase = .failed(e.localizedDescription)
        }
    }

    private func publish(name: String, port: UInt16, records: [String: Data]) {
        service?.stop()
        let s = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: Int32(port))
        s.setTXTRecord(NetService.data(fromTXTRecord: records))
        s.publish()
        service = s
    }

    private func stopListening() {
        service?.stop()
        service = nil
        // 只 shutdown：讓背景的 accept() 醒來，socket 由背景那邊關
        if listenFD >= 0 { Darwin.shutdown(listenFD, SHUT_RDWR) }
        listenFD = -1
    }

    /// 背景執行：準備身分 → 開 TCP 等手機連進來 → 跑 pair-setup → 回傳配對檔內容
    nonisolated private static func pair(
        ready: (_ fd: Int32, _ name: String, _ port: UInt16, _ records: [String: Data]) -> Bool
    ) -> Result<Data, LinkError> {
        func fail(_ step: String, _ err: UnsafeMutablePointer<IdeviceFfiError>?) -> Result<Data, LinkError> {
            var detail = "未知錯誤"
            if let err {
                detail = err.pointee.message.map { String(cString: $0) } ?? detail
                idevice_error_free(err)
            }
            return .failure(LinkError(step: step, detail: detail))
        }

        var host: OpaquePointer?
        var sidPtr: UnsafeMutablePointer<CChar>?
        var txtPtr: UnsafeMutablePointer<UInt8>?
        var txtLen: UInt = 0
        if let e = pairable_host_prepare("WanderLine", nil, false, &host, &sidPtr, &txtPtr, &txtLen, nil) {
            return fail("準備配對失敗", e)
        }
        defer {
            pairable_host_free(host)
            idevice_string_free(sidPtr)
            idevice_data_free(txtPtr, txtLen)
        }
        guard let sidPtr, let txtPtr else { return fail("準備配對失敗", nil) }
        let name = String(cString: sidPtr)

        // TXT 紀錄是一份 plist 字典
        let txtData = Data(bytes: txtPtr, count: Int(txtLen))
        guard let dict = (try? PropertyListSerialization.propertyList(from: txtData, format: nil)) as? [String: Any] else {
            return fail("準備配對失敗", nil)
        }
        var records: [String: Data] = [:]
        for (k, v) in dict {
            if let s = v as? String { records[k] = Data(s.utf8) }
            else if let d = v as? Data { records[k] = d }
            else if let n = v as? NSNumber { records[k] = Data(n.stringValue.utf8) }
        }

        // 開一個 TCP 埠等手機連進來
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(LinkError(step: "開不了網路埠", detail: String(cString: strerror(errno)))) }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            return .failure(LinkError(step: "開不了網路埠", detail: String(cString: strerror(errno))))
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)

        guard ready(fd, name, port, records) else {
            return .failure(LinkError(step: "已取消", detail: "沒有配對"))
        }

        let conn = Darwin.accept(fd, nil, nil)
        guard conn >= 0 else { return .failure(LinkError(step: "已取消", detail: "沒有配對")) }
        defer { Darwin.close(conn) }
        guard isSameDevice(conn) else {
            return .failure(LinkError(step: "連進來的是別台裝置", detail: "請在這支 iPhone 的「設定」裡點配對"))
        }

        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        var file: OpaquePointer?
        if let e = pairable_host_accept_fd(host, conn, pairingPINCallback, nil, &peer, &file) {
            return fail("配對沒有完成（代碼輸入錯誤或取消了）", e)
        }
        defer {
            rppairing_peer_device_free(peer)
            rp_pairing_file_free(file)
        }

        var bytes: UnsafeMutablePointer<UInt8>?
        var count: UInt = 0
        if let e = rp_pairing_file_to_bytes(file, &bytes, &count) { return fail("存配對檔失敗", e) }
        guard let bytes else { return fail("存配對檔失敗", nil) }
        let data = Data(bytes: bytes, count: Int(count))
        idevice_data_free(bytes, count)
        return .success(data)
    }

    /// 連進來的位址跟自己一樣 = 就是這支手機
    nonisolated private static func isSameDevice(_ conn: Int32) -> Bool {
        var peer = sockaddr_in(), local = sockaddr_in()
        var pl = socklen_t(MemoryLayout<sockaddr_in>.size), ll = pl
        let a = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(conn, $0, &pl) } }
        let b = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(conn, $0, &ll) } }
        guard a == 0, b == 0, peer.sin_family == sa_family_t(AF_INET), local.sin_family == sa_family_t(AF_INET) else { return false }
        return peer.sin_addr.s_addr == local.sin_addr.s_addr
    }
}

/// idevice 產生配對碼時叫這個（在背景執行緒）
private let pairingPINCallback: PairableHostPinCb = { pin, _ in
    guard let pin else { return }
    let code = String(cString: pin)
    Task { @MainActor in PairingHost.shared.showPIN(code) }
}
