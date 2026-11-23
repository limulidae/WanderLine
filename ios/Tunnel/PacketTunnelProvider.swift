// 本機 VPN：只接管送往 10.7.0.1 的封包，把來源和目的地對調後原封不動送回手機。
// 這樣 WanderLine 連 10.7.0.1 時，系統會以為是「外面的電腦」連進來，就肯讓我們用開發者服務。
// 不會連到任何外部伺服器，其他網路流量完全不經過這裡。
// 做法參考 StosVPN / LocalDevVPN（SideStore 團隊、jkcoxson）。
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let localIP = "10.7.1.1"
    static let peerIP = "10.7.0.1"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let v4 = NEIPv4Settings(addresses: [Self.localIP], subnetMasks: ["255.255.255.255"])
        v4.includedRoutes = [NEIPv4Route(destinationAddress: Self.peerIP, subnetMask: "255.255.255.255")]
        v4.excludedRoutes = [NEIPv4Route.default()]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.peerIP)
        settings.ipv4Settings = v4

        setTunnelNetworkSettings(settings) { [weak self] error in
            if error == nil { self?.pump() }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    /// 讀進來的 IPv4 封包：來源（第 12–15 位元組）和目的地（第 16–19 位元組）對調再寫回去。
    /// 對調不會改變 IP／TCP 的檢查碼（加總順序無關），所以不用重算。
    private func pump() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var out = packets
            for i in out.indices where protocols[i].int32Value == AF_INET && out[i].count >= 20 {
                out[i].withUnsafeMutableBytes { raw in
                    for k in 12..<16 { raw.swapAt(k, k + 4) }
                }
            }
            self.packetFlow.writePackets(out, withProtocols: protocols)
            self.pump()
        }
    }
}
