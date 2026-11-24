package com.filmbox.app

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class RecoveryTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()

    @Test
    fun failedLibraryKeepsItsIndexAndOffersTheCorrectRecovery() = runBlocking {
        val graph = (ui.activity.application as FilmboxApplication).graph
        RecoveryServer().use { server ->
            val account = graph.cloud.connect("webdav", "", server.url, "qa", "synthetic")
            val library =
                Library(UUID.randomUUID().toString(), "恢复测试", account = account.id, folderId = "/")
            try {
                graph.addLibrary(library)
                ui.waitUntil(15000) {
                    library.id !in graph.ui.value.scanning &&
                        graph.ui.value.items.any { it.source == library.id }
                }
                server.status.set(403)
                graph.refresh(library.id)
                ui.waitUntil(15000) { graph.ui.value.issues[library.id] == RecoveryProblem.DENIED }
                assertTrue(graph.ui.value.items.any { it.source == library.id })
                ui.onNodeWithText("打开网盘").assertExists()
                ui.onNodeWithText("重新登录").assertDoesNotExist()
                screenshot("denied")
                val requests = server.calls.get()
                repeat(3) {
                    try {
                        graph.cloud.list(account.id, "/", "/")
                    } catch (_: CloudFailure) {}
                }
                // Denied is scoped to a folder; it must not log the whole account out.
                assertNull(graph.cloud.problem(account.id))
                assertTrue(server.calls.get() >= requests)
                server.status.set(401)
                graph.refresh(library.id)
                ui.waitUntil(15000) { graph.ui.value.issues[library.id] == RecoveryProblem.LOGIN }
                val before = server.calls.get()
                repeat(4) {
                    try {
                        graph.cloud.list(account.id, "/", "/")
                    } catch (_: CloudFailure) {}
                }
                assertEquals(before, server.calls.get())
                ui.onNodeWithText("重新登录").performClick()
                ui.waitUntil(5000) {
                    ui.onAllNodesWithText("WebDAV").fetchSemanticsNodes().isNotEmpty()
                }
                ui.onNodeWithText("添加资源库").assertDoesNotExist()
                ui.onNodeWithText("已连接的账号").assertDoesNotExist()
                screenshot("reconnect")
                ui.onNodeWithContentDescription("关闭").performClick()
                server.status.set(207)
                graph.cloud.connect("webdav", "", server.url, "qa", "synthetic", account.id)
                graph.refresh(library.id)
                ui.waitUntil(15000) {
                    library.id !in graph.ui.value.scanning && library.id !in graph.ui.value.issues
                }
                assertTrue(graph.ui.value.items.any { it.source == library.id })
            } finally {
                graph.removeLibrary(library.id)
                graph.cloud.disconnect(account.id)
            }
        }
    }

    @Test
    fun transientReadRecoversOnceAndRateLimitStopsRepeatedRequests() = runBlocking {
        val context = ui.activity.applicationContext
        val engine = CloudEngine(context)
        RecoveryServer().use { server ->
            val account = engine.connect("webdav", "", server.url, "qa", "synthetic")
            try {
                val before = server.calls.get()
                server.failNext.set(1)
                assertEquals(1, engine.list(account.id, "/", "/").length())
                assertEquals(before + 2, server.calls.get())
                assertNull(engine.problem(account.id))
                server.status.set(429)
                try {
                    engine.list(account.id, "/", "/")
                    fail("rate limit accepted")
                } catch (e: CloudFailure) {
                    assertEquals("rate_limited", e.reason)
                }
                val stopped = server.calls.get()
                repeat(5) {
                    try {
                        engine.list(account.id, "/", "/")
                    } catch (_: CloudFailure) {}
                }
                assertEquals(stopped, server.calls.get())
                assertEquals(RecoveryProblem.LIMITED, engine.problem(account.id))
                engine.allowRecovery(account.id)
                server.status.set(207)
                assertEquals(1, engine.list(account.id, "/", "/").length())
                assertNull(engine.problem(account.id))
            } finally {
                engine.disconnect(account.id)
            }
        }
    }

    private fun screenshot(name: String) {
        val instrumentation =
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val root =
            java.io.File(
                androidx.test.platform.app.InstrumentationRegistry.getArguments()
                    .getString("additionalTestOutputDir") ?: ui.activity.cacheDir.path,
                "recovery",
            )
        root.mkdirs()
        instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
            java.io.File(root, "$name.png").outputStream().use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }
    }
}

private class RecoveryServer : AutoCloseable {
    private val server = ServerSocket(0, 20, InetAddress.getByName("127.0.0.1"))
    private val executor = Executors.newCachedThreadPool()
    val url = "http://127.0.0.1:${server.localPort}/dav/"
    val status = AtomicInteger(207)
    val calls = AtomicInteger()
    val failNext = AtomicInteger()

    init {
        executor.submit {
            while (!server.isClosed) try {
                val socket = server.accept()
                executor.submit {
                    socket.use { client ->
                        val reader = client.getInputStream().bufferedReader()
                        reader.readLine() ?: return@use
                        var length = 0
                        while (true) {
                            val line = reader.readLine() ?: break
                            if (line.isEmpty()) break
                            if (line.startsWith("Content-Length:", true))
                                length = line.substringAfter(':').trim().toInt()
                        }
                        repeat(length) { reader.read() }
                        calls.incrementAndGet()
                        val code =
                            if (failNext.getAndUpdate { (it - 1).coerceAtLeast(0) } > 0) 503
                            else status.get()
                        val body =
                            if (code == 207)
                                """<multistatus xmlns="DAV:"><response><href>/dav/photo.jpg</href><propstat><prop><displayname>photo.jpg</displayname><getcontentlength>128</getcontentlength><getlastmodified>Mon, 09 Nov 2026 12:00:00 GMT</getlastmodified></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"""
                                    .toByteArray()
                            else byteArrayOf()
                        client.getOutputStream().apply {
                            write(
                                "HTTP/1.1 $code Result\r\nContent-Type: application/xml\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                                    .toByteArray()
                            )
                            write(body)
                            flush()
                        }
                    }
                }
            } catch (_: Exception) {}
        }
    }

    override fun close() {
        server.close()
        executor.shutdownNow()
    }
}
