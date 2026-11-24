import Foundation

/// Stable evidence codes survive index checkpoints. UI never diagnoses by searching error prose.
public enum ResourceProblem: String, Codable, Sendable, CaseIterable {
    case login = "authentication_expired", network = "network_unavailable", timeout = "network_timeout"
    case secure = "secure_connection_failed"
    case service = "provider_unavailable", limited = "rate_limited", denied = "access_denied"
    case missing = "not_found", offline = "storage_offline", permission = "storage_permission"
    case storage = "storage_full", engine = "engine_unavailable", unsupported = "unsupported_media"
    case incomplete = "incomplete"
    case unknown = "unknown"

    public init(code: String?) {
        switch code {
        case "auth_expired", "account_not_connected": self = .login
        case "provider_error": self = .service
        default: self = Self(rawValue: code ?? "") ?? .unknown
        }
    }
    public var title: String {
        switch self {
        case .login: "需要重新登录"
        case .network: "网络未连接"
        case .timeout: "连接超时"
        case .secure: "无法验证云盘连接"
        case .service: "云盘暂时不可用"
        case .limited: "云盘请求受限"
        case .denied: "云盘拒绝访问"
        case .missing: "找不到文件或文件夹"
        case .offline: "资源库未连接"
        case .permission: "需要访问权限"
        case .storage: "存储空间不足"
        case .engine: "云盘连接组件不可用"
        case .unsupported: "无法预览此文件"
        case .incomplete: "原文件未完整读取"
        case .unknown: "未能完成加载"
        }
    }
    public var detail: String {
        switch self {
        case .login: "登录已失效，重新登录后会继续加载。已缓存的内容仍可查看。"
        case .network: "请检查网络连接。连接恢复后会自动检查未完成的资源库。"
        case .timeout: "云盘未及时响应，已自动尝试恢复。请检查网络，或稍后刷新。"
        case .secure: "请检查服务器证书、HTTPS 地址和设备时间。可在浏览器中打开云盘确认连接。"
        case .service: "云盘服务未能完成请求，已自动尝试恢复。可在网盘中确认服务状态，稍后刷新。"
        case .limited: "云盘限制了请求频率，已停止连续请求。请稍后刷新。"
        case .denied: "云盘已拒绝访问。请在网盘中检查文件权限或账户限制；重新登录未必能解决。"
        case .missing: "文件或文件夹可能已移动或删除。刷新资源库以核对当前位置。"
        case .offline: "请连接存储设备。设备已连接时，可重新选择原文件夹恢复访问。"
        case .permission: "系统未允许访问。请重新授权原文件夹或照片。"
        case .storage: "请清理设备空间或应用缓存，再继续加载。"
        case .engine: "自动恢复连接未成功。请重新启动应用；仍有问题时重新安装最新版。"
        case .unsupported: "文件可能损坏，或当前设备不支持此格式。可用其他应用打开以确认。"
        case .incomplete: "收到的文件与索引大小不一致。请刷新资源库核对最新文件，并在网盘中确认原文件可正常打开。"
        case .unknown: "暂时无法确认原因。可复制诊断信息，便于进一步排查。"
        }
    }
    public var action: String {
        switch self {
        case .login: "重新登录"
        case .network, .timeout: "网络设置"
        case .service, .limited, .denied, .secure: "打开网盘"
        case .missing, .incomplete: "刷新资源库"
        case .offline: "重新连接"
        case .permission: "重新授权"
        case .storage: "打开设置"
        case .engine, .unknown: "复制诊断信息"
        case .unsupported: "用其他应用打开"
        }
    }
    public var canAutomaticallyRetry: Bool { [.network, .timeout, .service, .engine].contains(self) }
}
