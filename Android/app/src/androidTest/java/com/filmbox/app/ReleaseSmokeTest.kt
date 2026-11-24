package com.filmbox.app

import android.Manifest
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.net.Uri
import android.provider.MediaStore
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import java.io.File
import org.junit.*

/** Tests the installed, shrunk APK through public UI only; it does not call app internals. */
class ReleaseSmokeTest {
    @get:Rule(order = 0)
    val permissions: GrantPermissionRule =
        GrantPermissionRule.grant(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
    @get:Rule(order = 1) val ui = createAndroidComposeRule<MainActivity>()
    private var uri: Uri? = null

    private fun output(name: String) =
        File(
                InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
                    ?: ui.activity.getExternalFilesDir(null)!!.absolutePath,
                name,
            )
            .apply { parentFile?.mkdirs() }

    @Before
    fun seed() {
        val b = Bitmap.createBitmap(1200, 800, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(b)
        canvas.drawColor(0xff809da9.toInt())
        val p = Paint().apply { color = 0xffebd4a0.toInt() }
        canvas.drawCircle(870f, 220f, 90f, p)
        p.color = 0xff345258.toInt()
        canvas.drawRect(0f, 520f, 1200f, 800f, p)
        val resolver = ui.activity.contentResolver
        uri =
            resolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, "FILMBOX_RELEASE_QA.jpg")
                    put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/FilmboxQA")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                },
            )!!
        resolver.openOutputStream(uri!!)!!.use { b.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        b.recycle()
        resolver.update(
            uri!!,
            ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
            null,
            null,
        )
        ui.waitUntil(15000) {
            ui.onAllNodesWithContentDescription("FILMBOX_RELEASE_QA.jpg")
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
    }

    @After
    fun clean() {
        uri?.let { ui.activity.contentResolver.delete(it, null, null) }
    }

    private fun shot(name: String) {
        (runCatching { ui.onAllNodes(isRoot()).onLast().captureToImage().asAndroidBitmap() }
                .getOrElse { error ->
                    InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                        ?: throw error
                })
            .let { b ->
                output("release-$name.png").outputStream().use {
                    b.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
            }
    }

    @Test
    fun signedReleaseGalleryViewerReelAndDarkTheme() {
        ui.onNodeWithContentDescription("FILMBOX_RELEASE_QA.jpg").performClick()
        ui.onNodeWithContentDescription("关闭查看器").assertIsDisplayed()
        ui.onNodeWithContentDescription("媒体查看器").performTouchInput { doubleClick(center) }
        ui.onNodeWithContentDescription("媒体查看器")
            .assert(
                SemanticsMatcher.expectValue(
                    androidx.compose.ui.semantics.SemanticsProperties.StateDescription,
                    "250%",
                )
            )
        shot("viewer")
        ui.onNodeWithContentDescription("关闭查看器").performClick()
        ui.onNodeWithContentDescription("切换浏览模式").performClick()
        shot("reel")
        ui.onNodeWithContentDescription("资源库").performClick()
        ui.onNodeWithContentDescription("设置").performClick()
        ui.onNodeWithText("外观", substring = false).performClick()
        ui.onNodeWithText("深色", substring = false).performClick()
        shot("settings")
        val memory = android.os.Debug.MemoryInfo()
        android.os.Debug.getMemoryInfo(memory)
        output("release-memory.txt")
            .writeText(
                "totalPssKb=${memory.totalPss}\nnativePssKb=${memory.nativePss}\ndalvikPssKb=${memory.dalvikPss}\n"
            )
    }
}
