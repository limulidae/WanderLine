// 收藏的地點：存在手機裡（UserDefaults），點搜尋列就會列出來，地圖上用小星星標出
import CoreLocation
import Foundation

struct Favorite: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

@MainActor
final class FavoriteStore: ObservableObject {
    static let shared = FavoriteStore()
    @Published private(set) var items: [Favorite] = []
    private let key = "favorites"

    init() {
        // App 刪掉重裝後 UserDefaults 會清空，從鑰匙圈的備份拿回來
        let d = UserDefaults.standard.data(forKey: key) ?? Keychain.read(key)
        if let d, let v = try? JSONDecoder().decode([Favorite].self, from: d) { items = v }
    }

    /// 這個點附近 15 公尺內已經收藏過的
    func find(_ c: CLLocationCoordinate2D) -> Favorite? {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return items.first { CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: here) < 15 }
    }

    func add(name: String, at c: CLLocationCoordinate2D) {
        let n = name.trimmingCharacters(in: .whitespaces)
        items.insert(Favorite(name: n.isEmpty ? String(format: "%.5f, %.5f", c.latitude, c.longitude) : n,
                              lat: c.latitude, lon: c.longitude), at: 0)
        persist()
    }

    func rename(_ f: Favorite, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = items.firstIndex(where: { $0.id == f.id }) else { return }
        items[i].name = n
        persist()
    }

    func remove(_ f: Favorite) {
        items.removeAll { $0.id == f.id }
        persist()
    }

    /// 幫收藏取預設名字：附近的地標、地名或路名
    static func suggestName(for c: CLLocationCoordinate2D) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude),
                                                                   preferredLocale: Locale(identifier: "zh-Hant-TW"))
        guard let p = marks?.first else { return nil }
        return p.areasOfInterest?.first ?? p.name ?? p.thoroughfare
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key); Keychain.write(d, key) }
    }
}
