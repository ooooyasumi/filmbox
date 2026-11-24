import Foundation
import FilmboxCore
@testable import Filmbox

@main @MainActor struct CloudWebMIntentChecks {
    static func main() async throws {
        let item = MediaItem(cloud: CloudMediaReference(accountID: UUID(), fileID: UUID().uuidString, parentID: "0", remotePath: "/not-downloaded.webm", revision: UUID().uuidString),
                             kind: .video, fileSize: 500_000_000, modifiedDate: .now, createdDate: .now)
        let web = WebVideoPlayback()
        web.update(item: item, muted: true, enabled: true, controls: false, loop: true)
        for _ in 0..<100 { if web.needsOriginalDownload { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(web.needsOriginalDownload && !web.failed && !web.isLoading && !web.isDownloadingOriginal)
        precondition(web.webView == nil && !web.canTogglePlayback && !web.isPlaying)
        for _ in 0..<5 { web.update(item: item, muted: true, enabled: true, controls: false, loop: true) }
        precondition(web.needsOriginalDownload && !web.isLoading && web.webView == nil)
        precondition(CloudTransferCenter.shared.snapshot(for: item.id, purpose: .original) == nil)
        web.stop()
        precondition(!web.needsOriginalDownload && !web.isDownloadingOriginal && web.originalDownloadError == nil)
        let browse = BrowseVideoPlayback()
        browse.update(item: item, muted: true, enabled: true)
        for _ in 0..<100 { if browse.needsOriginalDownload { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(browse.needsOriginalDownload && !browse.failed && !browse.isLoading && !browse.canTogglePlayback)
        precondition(browse.originalFileSize == 500_000_000)
        browse.stop()
        precondition(!browse.needsOriginalDownload && !browse.isDownloadingOriginal)
        print("8/8 cloud WebM intent checks passed: static download gate, no network/original queue, no implicit retry, browse propagation, stop cleanup")
    }
}
