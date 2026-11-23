// 控制 App 內建的本機 VPN（Tunnel 擴充功能）：第一次會跳出系統的「加入 VPN 設定」詢問。
// 設成「需要時自動連線」，手機重開機後也會自己接上。
import Foundation
import NetworkExtension

@MainActor
final class LoopbackVPN: ObservableObject {
    static let shared = LoopbackVPN()
    static let providerID = "wang.chunchieh.wanderline.tunnel"

    /// 設定頁顯示用：nil = 還沒查
    @Published private(set) var installed: Bool?
    @Published private(set) var connected = false

    private var observer: NSObjectProtocol?

    func refresh() async {
        let m = try? await find()
        installed = m != nil
        connected = m?.connection.status == .connected
        watch(m)
    }

    /// 確保 VPN 已加入並連上；連不上就丟出看得懂的錯誤
    func ensureOn() async throws {
        let m: NETunnelProviderManager
        do {
            if let found = try await find() {
                m = found
            } else {
                m = try await create()
            }
        } catch {
            installed = false
            throw LinkError(step: "本機 VPN 沒有加入", detail: "系統問「加入 VPN 設定」時要按「允許」（\(error.localizedDescription)）")
        }
        installed = true
        watch(m)

        if !m.isEnabled || !m.isOnDemandEnabled {
            m.isEnabled = true
            m.isOnDemandEnabled = true
            try? await m.saveToPreferences()
            try? await m.loadFromPreferences()
        }
        if m.connection.status == .connected { connected = true; return }
        if m.connection.status != .connecting {
            do { try m.connection.startVPNTunnel() } catch {
                throw LinkError(step: "本機 VPN 開不起來", detail: error.localizedDescription)
            }
        }
        for _ in 0..<40 {
            if m.connection.status == .connected { connected = true; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LinkError(step: "本機 VPN 開不起來", detail: "到「設定 → VPN」看 WanderLine 是不是被關掉了")
    }

    // MARK: - 內部

    private func find() async throws -> NETunnelProviderManager? {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        return all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID }
    }

    private func create() async throws -> NETunnelProviderManager {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerID
        proto.serverAddress = "只連這支 iPhone 自己"

        let m = NETunnelProviderManager()
        m.localizedDescription = "WanderLine"
        m.protocolConfiguration = proto
        m.isEnabled = true
        m.onDemandRules = [NEOnDemandRuleConnect()]
        m.isOnDemandEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        return m
    }

    private func watch(_ m: NETunnelProviderManager?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let m else { return }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: m.connection, queue: .main) { [weak self] _ in
            let on = m.connection.status == .connected
            Task { @MainActor in self?.connected = on }
        }
    }
}
