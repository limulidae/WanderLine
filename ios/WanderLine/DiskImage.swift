// 開發者映像檔（DDI）：改位置的開發者服務要先掛上它。
// 檔案從 doronz88/DeveloperDiskImage 下載一次（約 17 MB）存在 App 裡，之後每次連線時發現沒掛上就自動掛。
// iOS 26.4 以上用 cryptex 的版本，舊版用 personalized 的版本。
import Foundation

enum DiskImage {
    static var useCryptex: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4)
    }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(useCryptex ? "DDI-cryptex" : "DDI-personalized", isDirectory: true)
    }

    static var files: [String] {
        useCryptex
            ? ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"]
            : ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
    }

    static var ready: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// 下載缺少的檔案；progress 回報 0…1
    static func download(progress: (@MainActor (Double) -> Void)? = nil) async throws {
        let folder = useCryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized"
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, name) in files.enumerated() {
            await progress?(Double(i) / Double(files.count))
            let dest = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            let url = URL(string: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/\(folder)/\(name)")!
            let (tmp, res) = try await URLSession.shared.download(from: url)
            guard let http = res as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LinkError(title: "開發者映像檔下載失敗", todo: "稍後再試一次", tech: "\(name)：伺服器回應 \((res as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        await progress?(1)
    }

    /// 掛載失敗時清掉，下次重新下載
    static func reset() {
        try? FileManager.default.removeItem(at: dir)
    }
}
