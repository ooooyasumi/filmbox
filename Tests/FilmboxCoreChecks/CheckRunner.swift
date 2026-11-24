import Foundation
import Darwin

@main
struct CoreCheckRunner {
    static func main() async {
        let checks: [(String, () async throws -> Void)] = [
            ("父目录选择、子目录排除及部分选择恢复", { try parentSelectionCanExcludeChildAndRestorePartialParent() }),
            ("最具体路径规则和目录边界", { try mostSpecificRuleWinsAndDirectoryBoundariesAreRespected() }),
            ("子目录选择与平行资源库", { try selectingChildMarksAncestorPartialAndPreservesSibling() }),
            ("根目录和路径标准化", { try rootAndNormalizedPathsHavePredictableRules() }),
            ("目录、收藏和离线元数据持久化", { try persistenceRoundTripRetainsLibrariesFavoritesAndOfflineMetadata() }),
            ("缺失记录与损坏记录区分", { try absentCatalogIsEmptyButCorruptCatalogReportsErrorAndPreservesBytes() }),
            ("旧记录兼容迁移", { try catalogWithoutCacheMigratesToEmptyCache() }),
            ("隐藏状态和逻辑影集持久化", { try catalogRoundTripsHiddenMembershipAndLogicalAlbums() }),
            ("损坏管理字段不被静默重置", { try malformedManagementFieldsRemainReportedAsCorruption() }),
            ("损坏记录唯一备份且保留原件", { try corruptCatalogBackupIsUniqueAndPreservesOriginal() }),
            ("递归扫描、去重、隐藏文件、软件包和链接", { try await scannerRecursesDeduplicatesAndIgnoresHiddenPackagesAndSymlinks() }),
            ("EXIF 原始拍摄时间、相机及旋转尺寸", { try await scannerReadsOriginalExifDateCameraAndOrientedDimensions() }),
            ("无 EXIF 的照片时间回退", { try await scannerUsesFilesystemDatesWhenImageHasNoExif() }),
            ("视频真实尺寸与时长", { try await scannerReadsVideoDimensionsAndDuration() }),
            ("扫描缓存命中、变更失效与删除", { try await scannerCachesUnchangedRevisionsAndInvalidatesChangedOrDeletedFiles() }),
            ("重启复用持久照片索引及完整变更检查", { try await scannerRestoresPersistedImageMetadataAndChecksAllRevisionFields() }),
            ("重启复用真实视频元数据及变更失效", { try await scannerRestoresPersistedVideoMetadataWithoutReopeningAsset() }),
            ("缩放档位与日期聚合稳定性", { try temporalZoomBandsAggregateStably() }),
            ("按天分组、逆序和组内输入顺序", { try temporalDayGroupingPreservesInputOrderAndUsesExclusiveEnds() }),
            ("跨年周、月份与中文日期标题", { try temporalWeeksAndMonthsHandleYearBoundaries() }),
            ("夏令时中的日期边界", { try temporalGroupingUsesCalendarAcrossDaylightSavingChanges() }),
            ("拍摄、创建和修改时间分组", { try temporalDateBasisSelectsRequestedMetadataAndCaptureFallback() }),
            ("四种屏幕宽度下原始比例与布局边界", { try temporalLayoutPreservesRatiosBoundsAndOrderAtFourWindowWidths() }),
            ("极窄窗口、极端比例与密集竖图", { try temporalLayoutHandlesNarrowWindowsExtremeRatiosAndDensePortraits() }),
            ("末行自然大小与全景独立排版", { try temporalLayoutKeepsShortRowsNaturalAndPanoramasIndependent() })
        ]
        var failed = 0
        for (name, check) in checks {
            do {
                try await check()
                print("✓ \(name)")
            } catch {
                failed += 1
                print("✗ \(name)：\(error)")
            }
        }
        print("\(checks.count - failed)/\(checks.count) 检查通过")
        if failed > 0 { exit(EXIT_FAILURE) }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else { throw CheckFailure(message: "断言失败 \(file):\(line)") }
}

func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(message: "缺少必要结果 \(file):\(line)") }
    return value
}

func expectThrows<E: Error, T>(_ type: E.Type, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) throws {
    do {
        _ = try body()
    } catch is E {
        return
    }
    throw CheckFailure(message: "未抛出预期错误 \(type) \(file):\(line)")
}
