package com.filmbox.app

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.net.ServerSocket
import java.util.concurrent.Executors
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceCoreTest {
    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun localFilesNeverEnterOriginalDownloadTasks() = runBlocking {
        val graph = (context.applicationContext as FilmboxApplication).graph
        val media =
            Media(
                "local-download-guard",
                "gallery",
                "content://qa/local",
                "local.jpg",
                "image/jpeg",
            )
        val before = graph.ui.value.downloads
        try {
            graph.download(media)
            fail("Local file entered a cloud download")
        } catch (_: IllegalArgumentException) {}
        assertEquals(before, graph.ui.value.downloads)
        assertFalse(media.revision in graph.ui.value.originalTransfers)
    }

    @Test
    fun databaseReindexPreservesOrganizationAndInvalidatesChangedMedia() {
        val name = "qa-${System.nanoTime()}.db"
        val db = MediaDatabase(context, name)
        try {
            val a =
                Media(
                    "A",
                    "test",
                    "content://test/a",
                    "a.jpg",
                    "image/jpeg",
                    size = 4,
                    modified = 1,
                )
            val b = a.copy(id = "B", name = "b.jpg")
            db.replace("test", listOf(a, b))
            db.mark(setOf(a.identityKey), favorite = true, hidden = true)
            val album = db.addAlbum("旅途")
            db.membership(album, setOf(a.identityKey), true)
            db.replace("test", listOf(a.copy(size = 9, modified = 2)))
            val read = db.read().single()
            assertTrue(read.favorite)
            assertTrue(read.hidden)
            assertTrue(album in read.albums)
            assertEquals(9, read.size)
            assertEquals(2, read.modified)
            db.replace("other", listOf(b.copy(source = "other")))
            assertEquals(2, db.read().size)
            assertTrue(db.read().all { it.hidden && album in it.albums })
            db.removeSource("other")
            assertEquals(1, db.read().size)
            db.dimensions("A", 640, 480)
            assertEquals(640, db.read().single().width)
            db.replace("test", listOf(a.copy(size = 9, modified = 2)))
            assertEquals(640, db.read().single().width)
            assertTrue(db.read().single().dimensionsVerified)
            db.dimensions("A", 300, 200, false)
            assertFalse(db.read().single().dimensionsVerified)
        } finally {
            db.close()
            context.deleteDatabase(name)
        }
    }

    @OptIn(coil.annotation.ExperimentalCoilApi::class)
    @Test
    fun originalPosterTakesPriorityOverCachedNetworkThumbnail() = runBlocking {
        val graph = (context.applicationContext as FilmboxApplication).graph
        val m =
            Media(
                "qa-cache-priority",
                "qa",
                "",
                "qa.jpg",
                "image/jpeg",
                modified = System.nanoTime(),
                remoteId = "qa",
            )
        val hash =
            java.security.MessageDigest.getInstance("SHA-256")
                .digest(m.revision.toByteArray())
                .joinToString("") { "%02x".format(it) }
        val file = java.io.File(context.cacheDir, "posters/$hash.jpg")
        file.parentFile!!.mkdirs()
        file.writeText("hd-poster")
        val cache = coil.Coil.imageLoader(context).diskCache!!
        val key = "preview:${m.revision}"
        cache.openEditor(key)!!.let { edit ->
            edit.data.toFile().writeText("small-thumbnail")
            edit.metadata.toFile().writeText("")
            edit.commit()
        }
        try {
            assertEquals(file, graph.preview(m))
        } finally {
            file.delete()
            cache.remove(key)
        }
    }

    @Test
    fun bundledCloudSourceCanBeExported() {
        context.assets.open("cloud-source.tgz").use { compressed ->
            java.util.zip.GZIPInputStream(compressed).use { source ->
                val header = ByteArray(512)
                assertEquals(512, source.read(header))
                assertTrue(String(header).contains("CloudEngine"))
            }
        }
    }

    @Test
    fun vaultEncryptsAndRestoresSecrets() {
        val vault = CredentialVault(context)
        val id = "qa-${System.nanoTime()}"
        val credential = "private-qa-cookie"
        try {
            vault.write(
                id,
                org.json.JSONObject().put("provider", "quark").put("credential", credential),
            )
            assertEquals(credential, vault.read(id)!!.getString("credential"))
            val stored = context.getSharedPreferences("cloud-vault", 0).getString(id, "")!!
            assertFalse(stored.contains(credential))
        } finally {
            vault.remove(id)
        }
    }

    @Test
    fun nativeCloudEngineIndexesAndStreamsWebDavWithoutThumbnailDownloadingOriginal() =
        runBlocking {
            val bitmap =
                Bitmap.createBitmap(240, 160, Bitmap.Config.ARGB_8888).apply {
                    eraseColor(Color.BLUE)
                }
            val data =
                java.io
                    .ByteArrayOutputStream()
                    .also { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
                    .toByteArray()
            bitmap.recycle()
            val server = ServerSocket(0, 20, java.net.InetAddress.getByName("127.0.0.1"))
            val executor = Executors.newCachedThreadPool()
            var gets = 0
            executor.submit {
                while (!server.isClosed) {
                    try {
                        val socket = server.accept()
                        executor.submit {
                            socket.use { s ->
                                val reader = s.getInputStream().bufferedReader()
                                val line = reader.readLine() ?: return@use
                                val headers = mutableMapOf<String, String>()
                                while (true) {
                                    val h = reader.readLine() ?: break
                                    if (h.isEmpty()) break
                                    headers[h.substringBefore(':').lowercase()] =
                                        h.substringAfter(':').trim()
                                }
                                val bodyLength = headers["content-length"]?.toIntOrNull() ?: 0
                                repeat(bodyLength) { reader.read() }
                                val prop = line.startsWith("PROPFIND")
                                val body =
                                    if (prop)
                                        """<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/photo.jpg</d:href><d:propstat><d:prop><d:displayname>photo.jpg</d:displayname><d:getcontentlength>${data.size}</d:getcontentlength><d:getlastmodified>Mon, 09 Nov 2026 12:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"""
                                            .toByteArray()
                                    else {
                                        gets++
                                        data
                                    }
                                val out = s.getOutputStream()
                                out.write(
                                    "HTTP/1.1 ${if(prop)"207 Multi-Status" else "200 OK"}\r\nContent-Type: ${if(prop)"application/xml" else "image/jpeg"}\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                                        .toByteArray()
                                )
                                out.write(body)
                                out.flush()
                            }
                        }
                    } catch (_: Exception) {}
                }
            }
            val engine = CloudEngine(context)
            var id: String? = null
            try {
                val a =
                    engine.connect(
                        "webdav",
                        "",
                        "http://127.0.0.1:${server.localPort}/dav/",
                        "qa",
                        "secret",
                    )
                id = a.id
                val entries = engine.list(a.id, "/", "/")
                assertEquals(1, entries.length())
                assertEquals("photo.jpg", entries.getJSONObject(0).getString("name"))
                val m =
                    Media(
                        "remote",
                        a.id,
                        "",
                        "photo.jpg",
                        "image/jpeg",
                        remoteId = "/photo.jpg",
                        remotePath = "/photo.jpg",
                    )
                try {
                    engine.resolve(m, "thumbnail")
                    fail("WebDAV must not use the original as a thumbnail")
                } catch (e: CloudFailure) {
                    assertEquals("thumbnail_unavailable", e.reason)
                }
                assertEquals(0, gets)
                val url = engine.resolve(m, "original")
                assertTrue(url.startsWith("http://127.0.0.1:"))
                engine.http.newCall(Request.Builder().url(url).build()).execute().use {
                    assertTrue(it.isSuccessful)
                    assertArrayEquals(data, it.body!!.bytes())
                }
                assertEquals(1, gets)
                OkHttpClient().newCall(Request.Builder().url(url).build()).execute().use {
                    assertEquals(401, it.code)
                }
                engine.http
                    .newCall(
                        Request.Builder()
                            .url(url)
                            .header("Origin", "https://untrusted.invalid")
                            .build()
                    )
                    .execute()
                    .use { assertEquals(403, it.code) }
            } finally {
                engine.stop()
                id?.let { engine.vault.remove(it) }
                server.close()
                executor.shutdownNow()
            }
        }
}
