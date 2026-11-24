package com.filmbox.app

import android.Manifest
import android.content.ContentValues
import android.content.pm.ActivityInfo
import android.graphics.*
import android.net.Uri
import android.provider.MediaStore
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import java.io.File
import org.junit.*
import org.junit.Assert.*

/**
 * Disposable emulator fixtures only. Nothing in this class or its media ships in the production
 * APK.
 */
class GalleryUiTest {
    @get:Rule(order = 0)
    val permissions: GrantPermissionRule =
        GrantPermissionRule.grant(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
    @get:Rule(order = 1) val ui = createAndroidComposeRule<MainActivity>()
    private val inserted = mutableListOf<Uri>()
    private val graph
        get() = (ui.activity.application as FilmboxApplication).graph

    @Before
    fun seed() {
        val resolver = ui.activity.contentResolver
        repeat(8) { i ->
            val w = if (i % 3 == 0) 800 else 1400
            val h = if (i % 3 == 0) 1200 else if (i == 2) 600 else 950
            val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(b)
            val p = Paint(Paint.ANTI_ALIAS_FLAG)
            val skies =
                intArrayOf(
                    0xff789ca8.toInt(),
                    0xffe8b294.toInt(),
                    0xff7298b6.toInt(),
                    0xff9aab96.toInt(),
                )
            p.shader =
                LinearGradient(
                    0f,
                    0f,
                    0f,
                    h.toFloat(),
                    skies[i % 4],
                    0xffe5ddd0.toInt(),
                    Shader.TileMode.CLAMP,
                )
            canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), p)
            p.shader = null
            p.color = 0xfff4e4be.toInt()
            canvas.drawCircle(w * .76f, h * .27f, w * .075f, p)
            repeat(4) { layer ->
                p.color = Color.rgb(48 + layer * 17, 76 + layer * 14, 78 + layer * 12)
                val path = Path()
                path.moveTo(0f, h * (.45f + layer * .11f))
                path.lineTo(w * .2f, h * (.28f + layer * .1f))
                path.lineTo(w * .46f, h * (.57f + layer * .07f))
                path.lineTo(w * .74f, h * (.37f + layer * .1f))
                path.lineTo(w.toFloat(), h * (.49f + layer * .1f))
                path.lineTo(w.toFloat(), h.toFloat())
                path.lineTo(0f, h.toFloat())
                path.close()
                canvas.drawPath(path, p)
            }
            val values =
                ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, "FILMBOX_QA_$i.jpg")
                    put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/FilmboxQA")
                    put(MediaStore.Images.Media.DATE_TAKEN, 1794268800000L - (i / 3) * 86400000L)
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
            inserted += uri
            resolver.openOutputStream(uri)!!.use { b.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            b.recycle()
            resolver.update(
                uri,
                ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                    put(MediaStore.Images.Media.DATE_TAKEN, 1794268800000L - (i / 3) * 86400000L)
                },
                null,
                null,
            )
        }
        val video =
            resolver.insert(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, "FILMBOX_QA_video.mp4")
                    put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/FilmboxQA")
                    put(MediaStore.Video.Media.DATE_TAKEN, 1794268800000L)
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                },
            )!!
        inserted += video
        InstrumentationRegistry.getInstrumentation().context.assets.open("qa-video.mp4").use { input
            ->
            resolver.openOutputStream(video)!!.use { input.copyTo(it) }
        }
        resolver.update(
            video,
            ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) },
            null,
            null,
        )
        ui.waitForIdle()
        ui.waitUntil(15000) { "gallery" !in graph.ui.value.scanning }
        ui.runOnUiThread { graph.refreshGallery() }
        try {
            ui.waitUntil(15000) {
                graph.ui.value.items
                    .map { it.uri }
                    .toSet()
                    .containsAll(inserted.map { it.toString() })
            }
        } catch (e: Exception) {
            throw AssertionError(
                "Seed failed: count=${graph.ui.value.items.size}, busy=${graph.ui.value.scanning}, problems=${graph.ui.value.problems}, permission=${graph.ui.value.permission}",
                e,
            )
        }
    }

    @After
    fun clean() {
        inserted.forEach { runCatching { ui.activity.contentResolver.delete(it, null, null) } }
    }

    private fun shot(name: String) {
        ui.waitForIdle()
        Thread.sleep(300)
        (InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                ?: error("Screenshot unavailable"))
            .let { b ->
                val output =
                    InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
                val dir =
                    if (output != null) File(output, "qa").apply { mkdirs() }
                    else File(ui.activity.getExternalFilesDir(null), "qa").apply { mkdirs() }
                File(dir, "$name.png").outputStream().use {
                    b.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            }
    }

    private fun assertViewerHeaderSafe() {
        ui.waitForIdle()
        var safe = androidx.core.graphics.Insets.NONE
        var density = 1f
        ui.runOnUiThread {
            safe =
                androidx.core.view.WindowInsetsCompat.toWindowInsetsCompat(
                        ui.activity.window.decorView.rootWindowInsets
                    )
                    .getInsetsIgnoringVisibility(
                        androidx.core.view.WindowInsetsCompat.Type.statusBars() or
                            androidx.core.view.WindowInsetsCompat.Type.displayCutout()
                    )
            density = ui.activity.resources.displayMetrics.density
        }
        val close = ui.onNodeWithContentDescription("关闭查看器").getUnclippedBoundsInRoot()
        val more = ui.onNodeWithContentDescription("更多").getUnclippedBoundsInRoot()
        assertTrue(
            "Toolbar overlaps status bar or cutout",
            close.top.value >= safe.top / density - 1,
        )
        assertTrue("Toolbar overlaps left cutout", close.left.value >= safe.left / density - 1)
        assertTrue(
            "Toolbar overlaps right cutout",
            more.right.value <=
                ui.activity.resources.displayMetrics.widthPixels / density - safe.right / density +
                    1,
        )
    }

    @Test
    fun gridViewerSelectionFiltersAndSettings() {
        ui.onNodeWithText("${graph.ui.value.items.count{!it.hidden}} 个项目").assertExists()
        ui.waitForIdle()
        ui.waitUntil(10000) {
            val bounds =
                ui.onAllNodesWithContentDescription("FILMBOX_QA_0.jpg")
                    .onFirst()
                    .fetchSemanticsNode()
                    .boundsInWindow
            val bitmap =
                InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                    ?: return@waitUntil false
            val color =
                bitmap.getPixel(
                    bounds.center.x.toInt().coerceIn(0, bitmap.width - 1),
                    (bounds.top + bounds.height * .3f).toInt().coerceIn(0, bitmap.height - 1),
                )
            bitmap.recycle()
            maxOf(Color.red(color), Color.green(color), Color.blue(color)) -
                minOf(Color.red(color), Color.green(color), Color.blue(color)) > 15
        }
        shot("01-gallery")
        ui.onAllNodesWithContentDescription("FILMBOX_QA_0.jpg").onFirst().performClick()
        ui.waitUntil(5000) {
            runCatching {
                    ui.onNodeWithContentDescription("关闭查看器").assertIsDisplayed()
                    true
                }
                .getOrDefault(false)
        }
        ui.onNodeWithContentDescription("媒体查看器").performTouchInput { doubleClick(center) }
        ui.onNodeWithContentDescription("媒体查看器")
            .assert(
                SemanticsMatcher.expectValue(
                    androidx.compose.ui.semantics.SemanticsProperties.StateDescription,
                    "250%",
                )
            )
        ui.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.SetProgress))
            .assertCountEquals(0)
        assertViewerHeaderSafe()
        ui.onNodeWithContentDescription("收藏", useUnmergedTree = true).performClick()
        ui.waitUntil { graph.ui.value.items.any { it.name == "FILMBOX_QA_0.jpg" && it.favorite } }
        ui.onNodeWithContentDescription("关闭查看器").performClick()
        ui.onNodeWithContentDescription("多选").performClick()
        ui.onAllNodesWithContentDescription("FILMBOX_QA_0.jpg").onFirst().performClick()
        ui.onNodeWithText("已选择 1 项").assertExists()
        shot("02-selection")
        ui.onNodeWithContentDescription("更多").performClick()
        ui.onAllNodesWithText("隐藏", substring = false).onLast().performClick()
        ui.waitUntil { ui.onAllNodesWithText("已选择 0 项").fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithContentDescription("完成选择").performClick()
        ui.onNodeWithContentDescription("筛选").performClick()
        ui.onNodeWithText("已下载").performClick()
        ui.onNodeWithText("重置").performClick()
        ui.onNodeWithContentDescription("关闭筛选").performClick()
        ui.waitForIdle()
        ui.onNodeWithContentDescription("资源库").performClick()
        ui.onNodeWithContentDescription("设置").performClick()
        ui.onNodeWithText("外观").assertExists()
        shot("03-settings")
        ui.onNodeWithText("外观", substring = false).performClick()
        ui.onNodeWithText("跟随系统", substring = false).assertExists()
        ui.onNodeWithContentDescription("返回").performClick()
        ui.onNodeWithText("关于", substring = false).performClick()
        ui.onNodeWithText("菲林盒 · filmbox", substring = false).assertExists()
        ui.onNodeWithText("隐私", substring = false).performClick()
        ui.onNodeWithText("百度默认授权页由", substring = true).assertExists()
        shot("11-privacy")
        ui.onNodeWithContentDescription("返回").performClick()
        ui.onNodeWithText("开源许可", substring = false).performClick()
        ui.onNodeWithContentDescription("返回").performClick()
        ui.onNodeWithText("关于", substring = false).assertExists()
        ui.onNodeWithContentDescription("返回").performClick()
        ui.onNodeWithText("帮助", substring = false).performClick()
        ui.onNodeWithText("照片流", substring = false).assertExists()
        ui.onNodeWithContentDescription("返回").performClick()
        ui.onNodeWithContentDescription("返回").performClick()
        ui.onNodeWithContentDescription("照片流").assertExists()
    }

    @Test
    fun pinchChangesDateGroupingAndLandscapeViewerUsesWholeWindow() {
        val grid = ui.onNodeWithContentDescription("照片流")
        grid.performTouchInput {
            pinch(
                Offset(center.x - 100, center.y),
                Offset(center.x - 35, center.y),
                Offset(center.x + 100, center.y),
                Offset(center.x + 35, center.y),
                durationMillis = 600,
            )
        }
        ui.onNodeWithText("2026年11月", substring = false).assertExists()
        ui.waitForIdle()
        val gridTop = grid.fetchSemanticsNode().boundsInRoot.top
        val photoTop =
            ui.onAllNodes(hasContentDescription("FILMBOX_QA_", substring = true))
                .fetchSemanticsNodes()
                .minOf { it.boundsInRoot.top }
        assertTrue(
            "Short library was left floating in empty space",
            photoTop - gridTop <= 16 * ui.activity.resources.displayMetrics.density,
        )
        shot("06-month-grid")
        ui.onAllNodesWithContentDescription("FILMBOX_QA_0.jpg").onFirst().performClick()
        val before = ui.onNodeWithContentDescription("媒体查看器").getUnclippedBoundsInRoot()
        ui.mainClock.advanceTimeBy(400)
        ui.onNodeWithContentDescription("媒体查看器").performTouchInput { click(center) }
        ui.waitUntil(5000) {
            ui.onAllNodesWithContentDescription("关闭查看器").fetchSemanticsNodes().isEmpty()
        }
        val after = ui.onNodeWithContentDescription("媒体查看器").getUnclippedBoundsInRoot()
        assertEquals(before.bottom - before.top, after.bottom - after.top)
        ui.mainClock.advanceTimeBy(400)
        ui.onNodeWithContentDescription("媒体查看器").performTouchInput { click(center) }
        ui.waitUntil(5000) {
            runCatching {
                    ui.onNodeWithContentDescription("关闭查看器").assertIsDisplayed()
                    true
                }
                .getOrDefault(false)
        }
        ui.onNodeWithContentDescription("媒体查看器").performTouchInput {
            pinch(
                Offset(center.x - 35, center.y),
                Offset(center.x - 95, center.y),
                Offset(center.x + 35, center.y),
                Offset(center.x + 95, center.y),
                durationMillis = 500,
            )
        }
        val zoom =
            ui.onNodeWithContentDescription("媒体查看器")
                .fetchSemanticsNode()
                .config[androidx.compose.ui.semantics.SemanticsProperties.StateDescription]
        assertTrue(zoom.removeSuffix("%").toInt() > 100)
        ui.runOnUiThread {
            ui.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        ui.waitUntil(5000) {
            ui.activity.resources.configuration.orientation ==
                android.content.res.Configuration.ORIENTATION_LANDSCAPE
        }
        ui.waitUntil(5000) {
            ui.onAllNodesWithContentDescription("关闭查看器").fetchSemanticsNodes().isEmpty()
        }
        shot("07-landscape-immersive")
        ui.mainClock.advanceTimeBy(400)
        ui.onNodeWithContentDescription("媒体查看器").performTouchInput { click(center) }
        ui.waitUntil(5000) {
            runCatching {
                    ui.onNodeWithContentDescription("关闭查看器").assertIsDisplayed()
                    true
                }
                .getOrDefault(false)
        }
        assertViewerHeaderSafe()
        shot("08-landscape-controls")
        ui.runOnUiThread {
            ui.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
    }

    @Test
    fun denseOverviewPinchesContinuouslyAndSnapsAroundFingerCenter() {
        val originals = graph.ui.value.items.filter { it.source == "gallery" }
        val fixtures = originals.filter { it.name.startsWith("FILMBOX_QA_") && !it.video }
        val libraryId = "stress-library-${System.nanoTime()}"
        ui.runOnUiThread {
            graph.addLibrary(Library(libraryId, "测试资源库", uri = "content://qa/stress"))
        }
        ui.waitUntil(10000) { libraryId !in graph.ui.value.scanning }
        val bulk =
            List(5000) { i ->
                fixtures[i % fixtures.size].copy(
                    id = "stress:$i",
                    source = libraryId,
                    identity = "stress:$i",
                    name = "STRESS_${i.toString().padStart(5,'0')}.jpg",
                    date = 1794268800000L - (i / 20) * 86400000L,
                )
            }
        try {
            kotlinx.coroutines.runBlocking {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    graph.db.replace(libraryId, bulk)
                    graph.reload()
                }
            }
            ui.waitUntil(10000) {
                ui.onAllNodes(hasContentDescription("STRESS_", substring = true))
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            val grid = ui.onNodeWithContentDescription("照片流")
            grid.performSemanticsAction(SemanticsActions.ScrollBy) { it(0f, 160000f) }
            ui.waitForIdle()
            val root = grid.fetchSemanticsNode().boundsInRoot
            val target =
                ui.onAllNodes(hasContentDescription("STRESS_", substring = true))
                    .fetchSemanticsNodes()
                    .minBy { (it.boundsInRoot.center - root.center).getDistance() }
            val name =
                target.config[androidx.compose.ui.semantics.SemanticsProperties.ContentDescription]
                    .first()
            val point = target.boundsInRoot.center - root.topLeft
            grid.performTouchInput {
                down(0, point + Offset(-100f, 0f))
                down(1, point + Offset(100f, 0f))
                moveTo(0, point + Offset(-110f, 0f))
                moveTo(1, point + Offset(110f, 0f))
            }
            ui.waitForIdle()
            val live =
                grid
                    .fetchSemanticsNode()
                    .config[androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo]
                    .current
            assertTrue(
                "Pinch skipped continuous geometry",
                GalleryDensityStops.none { kotlin.math.abs(it - live) < .1f },
            )
            assertTrue(
                ui.onAllNodes(hasContentDescription("日期：", substring = true))
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            )
            val anchored = ui.onNodeWithContentDescription(name).fetchSemanticsNode().boundsInRoot
            shot("09-pinch-in-progress")
            assertTrue(
                "Finger center lost its photo: target=$name point=${point+root.topLeft} bounds=$anchored",
                anchored.contains(point + root.topLeft),
            )
            grid.performTouchInput {
                up(0)
                up(1)
            }
            ui.waitForIdle()
            val snapped =
                grid
                    .fetchSemanticsNode()
                    .config[androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo]
                    .current
            assertTrue(GalleryDensityStops.any { kotlin.math.abs(it - snapped) < .1f })
            grid.performTouchInput {
                pinch(
                    Offset(center.x - 180, center.y),
                    Offset(center.x - 8, center.y),
                    Offset(center.x + 180, center.y),
                    Offset(center.x + 8, center.y),
                    durationMillis = 700,
                )
            }
            ui.waitForIdle()
            assertEquals(
                12f,
                grid
                    .fetchSemanticsNode()
                    .config[androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo]
                    .current,
                .1f,
            )
            Thread.sleep(1600)
            ui.onNodeWithText("2026年", substring = false).assertExists()
            shot("10-year-overview")
            assertTrue(graph.ui.value.originalTransfers.isEmpty())
            ui.onAllNodesWithText("正在下载").assertCountEquals(0)
            grid.performSemanticsAction(SemanticsActions.SetProgress) { it(150f) }
            ui.waitForIdle()
            ui.waitUntil(10000) {
                ui.onAllNodes(hasContentDescription("STRESS_", substring = true))
                    .fetchSemanticsNodes()
                    .isNotEmpty() &&
                    kotlin.math.abs(
                        grid
                            .fetchSemanticsNode()
                            .config[
                                androidx.compose.ui.semantics.SemanticsProperties
                                    .ProgressBarRangeInfo]
                            .current - 150f
                    ) < .1f
            }
        } finally {
            ui.runOnUiThread { graph.removeLibrary(libraryId) }
            kotlinx.coroutines.runBlocking {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    graph.db.removeSource(libraryId)
                    graph.reload()
                }
            }
        }
    }

    @Test
    fun reelKeepsFocusAndVideoCanOpen() {
        ui.onNodeWithContentDescription("切换浏览模式").performClick()
        ui.waitForIdle()
        shot("04-reel")
        ui.onNodeWithContentDescription("排序").performClick()
        ui.onNodeWithText("时间轴密度", substring = false).performClick()
        ui.onNode(SemanticsMatcher.keyIsDefined(SemanticsActions.SetProgress))
            .performSemanticsAction(SemanticsActions.SetProgress) { it(90f) }
        ui.onNodeWithText("按月").assertExists()
        ui.onNodeWithContentDescription("关闭密度设置").performClick()
        ui.onNodeWithText("11月", substring = false).assertExists()
        ui.onNodeWithContentDescription("下一项").performClick()
        ui.waitForIdle()
        ui.onNodeWithContentDescription("切换浏览模式").performClick()
        ui.onNodeWithText("视频", substring = false).performClick()
        ui.waitForIdle()
        ui.onAllNodesWithContentDescription("FILMBOX_QA_video.mp4").onFirst().performClick()
        ui.onNodeWithContentDescription("关闭查看器").assertExists()
        ui.waitUntil(10000) {
            ui.onAllNodesWithContentDescription("暂停").fetchSemanticsNodes().isNotEmpty()
        }
        ui.waitUntil(5000) {
            val screen =
                InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                    ?: return@waitUntil false
            val shown =
                listOf(4, 5, 6).any { x ->
                    val color = screen.getPixel(screen.width * x / 10, screen.height / 2)
                    Color.red(color) + Color.green(color) + Color.blue(color) > 80
                }
            screen.recycle()
            shown
        }
        ui.onNodeWithContentDescription("暂停").performClick()
        ui.waitUntil(5000) {
            ui.onAllNodesWithContentDescription("播放").fetchSemanticsNodes().isNotEmpty()
        }
        ui.onNodeWithContentDescription("播放").performClick()
        ui.waitUntil(5000) {
            ui.onAllNodesWithContentDescription("暂停").fetchSemanticsNodes().isNotEmpty()
        }
        shot("05-video")
    }
}
