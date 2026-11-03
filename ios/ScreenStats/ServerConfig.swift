import Foundation

/// 服务器地址的**唯一读取点**。
///
/// `UserDefaults` 键名冻结为 `serverHost`（String）与 `serverPort`（Int），
/// M5 的设置页写同样两个键。**除本文件外任何地方都不许直接读这两个键名。**
///
/// `load()` 返回 `nil` 即「未配置」——host 缺失或为空都算未配置。
struct ServerConfig {

    /// 配置键名（冻结）
    static let hostKey = "serverHost"
    static let portKey = "serverPort"

    /// 端口缺省值（design.md 的界面规格）
    static let defaultPort = 8737

    let host: String
    let port: Int

    /// 从 `UserDefaults` 读配置；host 缺失或为空 → `nil`（未配置）。
    static func load(from defaults: UserDefaults = .standard) -> ServerConfig? {
        guard let rawHost = defaults.string(forKey: hostKey) else { return nil }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        let storedPort = defaults.object(forKey: portKey) as? Int
        let port = storedPort.flatMap { (1...65535).contains($0) ? $0 : nil } ?? defaultPort
        return ServerConfig(host: host, port: port)
    }

    /// `GET /api/stats` 的完整 URL。host 含非法字符时返回 `nil`。
    var statsURL: URL? {
        URL(string: "http://\(host):\(port)/api/stats")
    }

    /// 把配置写进 `UserDefaults`（M5 的设置页入口）。
    ///
    /// **必须在主线程调用**：写入会同步投递 `UserDefaults.didChangeNotification`，
    /// 而 `DashboardViewController` 在该通知里重读配置并同步碰 UIKit
    /// （见 docs/design.md 的「设置入口」）。
    ///
    /// host 落盘前去掉首尾空白，与 `load()` 的归一化保持一致；端口**不做**校验回落，
    /// 由调用方（设置页）负责校验，非法值不进本方法。
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ServerConfig.hostKey)
        defaults.set(port, forKey: ServerConfig.portKey)
    }

    /// 清掉两个键，回到「未配置」态（`load()` 返回 `nil`）。
    ///
    /// 同样只在主线程调用，理由见 `save(to:)`。
    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: portKey)
    }
}
