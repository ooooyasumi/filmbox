import Foundation
import FilmboxCore

/// Shared wording for media progress in previews, viewers and cloud tasks.
enum MediaLoadingText {
    static let downloading = "正在下载"
    static let waiting = "等待下载"
    static let loading = "正在加载"
    static let paused = "已暂停"
}

/// State is evidence; an arbitrary framework error string is not a diagnosis.
/// Local decoding and even local WebM's loopback HTTP never imply a cloud issue.
enum MediaFailureText {
    static let failed = "无法加载"
    static let offline = "资源库未连接"
    static let login = "需要重新登录"
    static let noPreview = "暂无预览"

    static func title(for item: MediaItem, isOffline: Bool = false, needsLogin: Bool = false) -> String {
        if item.isLocal { return isOffline ? offline : failed }
        return item.cloud != nil && needsLogin ? login : failed
    }

    static func transferError(_ error: Error) -> String {
        // Preserve actionable, verified storage limits. Do not repeat arbitrary
        // URLSession/decoder strings (including "network" from loopback reads).
        if let error = error as? CloudConnectionError {
            switch error {
            case .problem(let issue): return issue.title + "。" + issue.detail
            case .credentialsMissing: return login
            case .cacheBudgetExceeded: return error.localizedDescription
            case .keychain: return "登录信息暂不可用，请稍后重试。"
            default: break
            }
        }
        return failed
    }

    static func problem(_ error: Error) -> ResourceProblem {
        if let value = error as? CloudConnectionError { return value.recoveryProblem }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain {
            if value.code == NSFileWriteOutOfSpaceError { return .storage }
            if value.code == NSFileReadNoPermissionError { return .permission }
            if value.code == NSFileNoSuchFileError { return .missing }
        }
        return .unknown
    }
}

struct MediaPlaceholderFeedback: Equatable {
    let title: String
    let symbol: String
    let spins: Bool

    static func resolve(item: MediaItem, loading: Bool, noPreview: Bool, needsLogin: Bool) -> Self {
        let cloud = item.cloud != nil && !item.url.isFileURL
        if cloud && needsLogin { return Self(title: MediaFailureText.login, symbol: "icloud.slash", spins: false) }
        if loading {
            return Self(title: MediaLoadingText.loading, symbol: item.kind == .image ? "photo" : "film", spins: cloud)
        }
        if cloud && noPreview { return Self(title: MediaFailureText.noPreview, symbol: item.kind == .image ? "photo" : "film", spins: false) }
        return Self(title: MediaFailureText.failed, symbol: cloud ? "exclamationmark.icloud" : "exclamationmark.triangle", spins: false)
    }
}
