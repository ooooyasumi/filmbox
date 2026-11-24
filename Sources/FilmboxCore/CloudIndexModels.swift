import Foundation

public enum CloudIndexPhase: String, Codable, Hashable, Sendable {
    case indexing
    case ready
    case failed
    case paused
}

public struct CloudIndexProgress: Codable, Equatable, Sendable {
    public var photos: Int
    public var videos: Int
    public var folders: Int
    public var phase: CloudIndexPhase
    public var error: String?
    public var errorCode: String?
    public var updatedAt: Date
    public var lastCompletedAt: Date?

    public init(photos: Int = 0, videos: Int = 0, folders: Int = 0, phase: CloudIndexPhase = .indexing,
                error: String? = nil, errorCode: String? = nil, updatedAt: Date = Date(), lastCompletedAt: Date? = nil) {
        self.photos = photos
        self.videos = videos
        self.folders = folders
        self.phase = phase
        self.error = error
        self.errorCode = errorCode
        self.updatedAt = updatedAt
        self.lastCompletedAt = lastCompletedAt
    }
}
