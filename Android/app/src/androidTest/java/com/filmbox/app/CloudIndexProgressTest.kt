package com.filmbox.app

import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** A real WorkManager task against a disposable WebDAV server, with no media download. */
class CloudIndexProgressTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()

    @Test
    fun progressRemainsVisibleAndIndexContinuesWhenActivityStops() {
        val graph = (ui.activity.application as FilmboxApplication).graph
        val server = ServerSocket(0, 20, InetAddress.getByName("127.0.0.1"))
        val workers = Executors.newCachedThreadPool()
        val gate = CountDownLatch(1)
        workers.submit {
            while (!server.isClosed) try {
                val socket = server.accept()
                workers.submit {
                    socket.use { s ->
                        val input = s.getInputStream().bufferedReader()
                        val request = input.readLine() ?: return@use
                        var length = 0
                        while (true) {
                            val header = input.readLine() ?: break
                            if (header.isEmpty()) break
                            if (header.startsWith("Content-Length:", true))
                                length = header.substringAfter(':').trim().toInt()
                        }
                        repeat(length) { input.read() }
                        val child = request.contains("/child")
                        if (child) gate.await(25, TimeUnit.SECONDS)
                        val entry = if (child) "two.jpg" else "one.jpg"
                        val prefix = if (child) "/dav/child/" else "/dav/"
                        val directory =
                            if (child) ""
                            else
                                "<d:response><d:href>/dav/child/</d:href><d:propstat><d:prop><d:displayname>child</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                        val body =
                            ("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>$prefix$entry</d:href><d:propstat><d:prop><d:displayname>$entry</d:displayname><d:getcontentlength>123</d:getcontentlength><d:getlastmodified>Mon, 09 Nov 2026 12:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>$directory</d:multistatus>")
                                .toByteArray()
                        s.getOutputStream().use { out ->
                            out.write(
                                "HTTP/1.1 207 Multi-Status\r\nContent-Type: application/xml\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                                    .toByteArray()
                            )
                            out.write(body)
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        val id = UUID.randomUUID().toString()
        var account: CloudAccount? = null
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
                    Library(id, "旅途", account = account!!.id, folderId = "/", path = "/")
                )
            }
            ui.waitUntil(15000) { graph.ui.value.indexing[id]?.found == 1 }
            ui.onNodeWithText("已找到 1 项", substring = false).assertExists()
            val output =
                InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")!!
            Thread.sleep(200)
            val screen =
                InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()!!
            File(output, "qa/index-progress.png")
                .apply { parentFile!!.mkdirs() }
                .outputStream()
                .use { screen.compress(Bitmap.CompressFormat.PNG, 100, it) }
            screen.recycle()
            ui.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            gate.countDown()
            runBlocking {
                withTimeout(15000) {
                    graph.ui.first { state -> state.items.count { it.source == id } == 2 }
                }
            }
            ui.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            ui.waitUntil(5000) { id !in graph.ui.value.indexing }
            assertEquals(2, graph.ui.value.items.count { it.source == id })
            assertNull(graph.cloudIndex.next(id))
        } finally {
            gate.countDown()
            ui.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            ui.runOnUiThread { graph.removeLibrary(id) }
            account?.let { runBlocking { graph.cloud.disconnect(it.id) } }
            server.close()
            workers.shutdownNow()
        }
    }
}
