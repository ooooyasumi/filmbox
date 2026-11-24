package com.filmbox.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Exercises the full cloud index → focused download → cached preview path with no real account. */
class CloudViewerTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()

    @Test
    fun downloadDoesNotDismissViewerWhenUndownloadedFilterStopsMatching() {
        val graph = (ui.activity.application as FilmboxApplication).graph
        val bitmap =
            Bitmap.createBitmap(1200, 800, Bitmap.Config.ARGB_8888).apply {
                eraseColor(0xff708c8a.toInt())
            }
        val bytes =
            java.io
                .ByteArrayOutputStream()
                .also { bitmap.compress(Bitmap.CompressFormat.JPEG, 94, it) }
                .toByteArray()
        bitmap.recycle()
        val server = ServerSocket(0, 20, InetAddress.getByName("127.0.0.1"))
        val workers = Executors.newCachedThreadPool()
        val gets = AtomicInteger(0)
        val firstDownload = CountDownLatch(1)
        workers.submit {
            while (!server.isClosed) try {
                val socket = server.accept()
                workers.submit {
                    socket.use { s ->
                        val input = s.getInputStream().bufferedReader()
                        val line = input.readLine() ?: return@use
                        var length = 0
                        while (true) {
                            val header = input.readLine() ?: break
                            if (header.isEmpty()) break
                            if (header.startsWith("Content-Length:", true))
                                length = header.substringAfter(':').trim().toInt()
                        }
                        repeat(length) { input.read() }
                        val prop = line.startsWith("PROPFIND")
                        if (!prop) {
                            if (gets.incrementAndGet() == 1)
                                firstDownload.await(15, TimeUnit.SECONDS)
                        }
                        val body =
                            if (prop)
                                """<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/CLOUD_UI_QA.jpg</d:href><d:propstat><d:prop><d:displayname>CLOUD_UI_QA.jpg</d:displayname><d:getcontentlength>${bytes.size}</d:getcontentlength><d:getlastmodified>Mon, 09 Nov 2026 12:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"""
                                    .toByteArray()
                            else bytes
                        s.getOutputStream().use { out ->
                            out.write(
                                "HTTP/1.1 ${if(prop)"207 Multi-Status" else "200 OK"}\r\nContent-Type: ${if(prop)"application/xml" else "image/jpeg"}\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                                    .toByteArray()
                            )
                            out.write(body)
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        var account: CloudAccount? = null
        val libraryId = UUID.randomUUID().toString()
        try {
            account = runBlocking {
                withContext(Dispatchers.IO) {
                    graph.cloud.connect(
                        "webdav",
                        "",
                        "http://127.0.0.1:${server.localPort}/dav/",
                        "qa",
                        "test-only",
                    )
                }
            }
            ui.runOnUiThread {
                graph.addLibrary(
                    Library(libraryId, "测试云库", account = account!!.id, folderId = "/", path = "/")
                )
            }
            try {
                ui.waitUntil(20000) { graph.ui.value.items.any { it.source == libraryId } }
            } catch (e: Throwable) {
                val jobs =
                    androidx.work.WorkManager.getInstance(ui.activity)
                        .getWorkInfosByTag(CloudIndexWorker.TAG)
                        .get()
                throw AssertionError(
                    "Cloud index failed: scanning=${graph.ui.value.scanning}, problems=${graph.ui.value.problems}, jobs=$jobs",
                    e,
                )
            }
            val media = graph.ui.value.items.first { it.source == libraryId }
            assertFalse(graph.isDownloaded(media))
            ui.onNodeWithContentDescription("筛选").performClick()
            ui.onNodeWithText("未下载", substring = false).performClick()
            ui.onNodeWithContentDescription("关闭筛选").performClick()
            ui.onNodeWithContentDescription("CLOUD_UI_QA.jpg").performClick()
            ui.onNodeWithText("正在下载").assertExists()
            ui.onNodeWithText("正在下载", substring = false).assertIsDisplayed()
            val notice = ui.onNodeWithText("正在下载", substring = false).getUnclippedBoundsInRoot()
            val viewerBounds = ui.onNodeWithContentDescription("媒体查看器").getUnclippedBoundsInRoot()
            val toolbar = ui.onNodeWithContentDescription("分享").getUnclippedBoundsInRoot()
            assertTrue(
                "Download notice must stay in the lower half",
                notice.top > viewerBounds.top + (viewerBounds.bottom - viewerBounds.top) / 2,
            )
            assertTrue("Download notice overlaps actions", notice.bottom < toolbar.top)
            assertTrue(media.revision in graph.ui.value.originalTransfers)
            firstDownload.countDown()
            ui.waitUntil(15000) { graph.isDownloaded(media) && graph.ui.value.downloads == 0 }
            ui.onNodeWithContentDescription("关闭查看器").assertIsDisplayed()
            ui.waitUntil(5000) {
                ui.onAllNodesWithContentDescription("CLOUD_UI_QA.jpg")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            ui.onNodeWithContentDescription("CLOUD_UI_QA.jpg").assertExists()
            assertFalse(media.revision in graph.ui.value.originalTransfers)
            val preview = runBlocking { graph.preview(media) }
            assertTrue(preview is File)
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile((preview as File).absolutePath, options)
            assertTrue(options.outWidth >= 1000)
            assertEquals(1200 to 800, runBlocking { graph.originalDimensions(media) })
            ui.onNodeWithContentDescription("关闭查看器").performClick()
            ui.onNodeWithText("没有符合条件的项目").assertExists()
            runBlocking { graph.clearCache(original = true, preview = false) }
            assertFalse(graph.isDownloaded(media))
            runBlocking {
                val first = async(Dispatchers.IO) { graph.download(media) }
                val second = async(Dispatchers.IO) { graph.download(media) }
                assertEquals(first.await(), second.await())
            }
            assertEquals(2, gets.get())
        } finally {
            firstDownload.countDown()
            ui.runOnUiThread { graph.removeLibrary(libraryId) }
            account?.let { a -> runBlocking { graph.cloud.disconnect(a.id) } }
            server.close()
            workers.shutdownNow()
        }
    }
}
