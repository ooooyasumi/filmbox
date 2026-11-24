package com.filmbox.app

import android.graphics.Bitmap
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** The queue behaves like a slow cloud source; no real account or media is used. */
class GalleryLoadingTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()

    @Test
    fun upgradingACloudPreviewKeepsItsOldPixelsUntilTheReplacementIsReady() {
        val graph = (ui.activity.application as FilmboxApplication).graph
        val photo =
            Media(
                "quality",
                "qa-preview",
                "",
                "quality.jpg",
                "image/jpeg",
                100,
                100,
                date = 1794268800000L,
                remoteId = "quality",
            )
        val data = GalleryData(listOf(photo))
        val viewport = GalleryViewport()
        viewport.reset(data, 150f, 400f, 700f)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val gate = CompletableDeferred<Unit>()
        var quality = 0
        lateinit var bank: GalleryPreviews
        ui.runOnUiThread {
            bank =
                GalleryPreviews(ui.activity, graph, scope, { false }, { quality }) { _, w, h ->
                    if (quality > 0) gate.await()
                    Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply {
                        eraseColor(if (quality == 0) 0xff708c8a.toInt() else 0xffe8b294.toInt())
                    }
                }
            bank.request(data, viewport.window(), 400f, 700f, 2f, 0)
        }
        try {
            ui.waitUntil(5000) { runBlocking(Dispatchers.Main) { bank.get(photo, 0) != null } }
            val before = runBlocking(Dispatchers.Main) { bank.get(photo, 0)!!.bitmap }
            ui.runOnUiThread {
                quality = 2
                bank.resetFailures()
                bank.request(data, viewport.window(), 400f, 700f, 2f, 0)
                assertSame(before, bank.get(photo, 0)!!.bitmap)
            }
            gate.complete(Unit)
            ui.waitUntil(5000) {
                runBlocking(Dispatchers.Main) { bank.get(photo, 0)?.bitmap !== before }
            }
            assertTrue(graph.ui.value.originalTransfers.isEmpty())
        } finally {
            ui.runOnUiThread {
                bank.close()
                scope.cancel()
            }
        }
    }

    @Test
    fun cancellingBeforeAWorkerStartsDoesNotPermanentlyOccupyItsSlot() {
        val graph = (ui.activity.application as FilmboxApplication).graph
        val data =
            GalleryData(
                List(500) { i ->
                    Media(
                        "early:$i",
                        "qa-preview",
                        "",
                        "$i.jpg",
                        "image/jpeg",
                        100,
                        100,
                        date = 1794268800000L,
                        remoteId = "$i",
                    )
                }
            )
        val viewport = GalleryViewport()
        viewport.reset(data, 80f, 400f, 700f)
        // Non-immediate Main deliberately queues worker bodies until this UI callback returns.
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        lateinit var bank: GalleryPreviews
        lateinit var target: GalleryWindow
        ui.runOnUiThread {
            bank =
                GalleryPreviews(ui.activity, graph, scope, { false }) { _, w, h ->
                    delay(2)
                    Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                }
            bank.request(data, viewport.window(), 400f, 700f, 2f, 0)
            viewport.scroll(-1400f)
            target = viewport.window()
            bank.request(data, target, 400f, 700f, 2f, 0)
        }
        try {
            val visible = target.tiles.filter { it.bounds.bottom > 0 && it.bounds.y < 700 }
            ui.waitUntil(10000) {
                runBlocking(Dispatchers.Main) {
                    visible.all { bank.get(data.items[it.index], 0) != null }
                }
            }
        } finally {
            ui.runOnUiThread {
                bank.close()
                scope.cancel()
            }
        }
    }

    @Test
    fun everyVisibleCloudPreviewLoadsInRadialOrderWithOnlyFourWorkers() {
        val graph = (ui.activity.application as FilmboxApplication).graph
        val data =
            GalleryData(
                List(10000) { i ->
                    Media(
                        "cloud:$i",
                        "qa-preview",
                        "",
                        "$i.jpg",
                        "image/jpeg",
                        100,
                        100,
                        date = 1794268800000L,
                        remoteId = "$i",
                    )
                }
            )
        val viewport = GalleryViewport()
        viewport.reset(data, 20f, 400f, 700f)
        val window = viewport.window()
        val plan = galleryPreviewOrder(window.tiles, 400f, 700f)
        val visible = plan.filter { it.bounds.bottom > 0 && it.bounds.y < 700 }
        assertTrue(visible.size > 500)
        val active = AtomicInteger()
        val maximum = AtomicInteger()
        val started = ConcurrentLinkedQueue<String>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        lateinit var bank: GalleryPreviews
        ui.runOnUiThread {
            bank =
                GalleryPreviews(ui.activity, graph, scope, { false }) { media, w, h ->
                    val count = active.incrementAndGet()
                    maximum.getAndUpdate { maxOf(it, count) }
                    started.add(media.id)
                    try {
                        delay(3)
                        Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply {
                            eraseColor(0xff708c8a.toInt())
                        }
                    } finally {
                        active.decrementAndGet()
                    }
                }
            bank.request(data, window, 400f, 700f, 2.625f, 0)
        }
        try {
            ui.waitUntil(15000) {
                runBlocking(Dispatchers.Main) {
                    plan.all { bank.get(data.items[it.index], 0) != null }
                }
            }
            val expected = plan.map { data.items[it.index].id }
            assertEquals(expected, started.toList())
            assertEquals(4, maximum.get())
            assertTrue(graph.ui.value.originalTransfers.isEmpty())
        } finally {
            ui.runOnUiThread {
                bank.close()
                scope.cancel()
            }
        }
    }

    @Test
    fun scrollingCancelsObsoletePreviewsAndStillCompletesTheNewViewport() {
        val graph = (ui.activity.application as FilmboxApplication).graph
        val data =
            GalleryData(
                List(10000) { i ->
                    Media(
                        "cancel:$i",
                        "qa-preview",
                        "",
                        "$i.jpg",
                        "image/jpeg",
                        100,
                        100,
                        date = 1794268800000L,
                        remoteId = "$i",
                    )
                }
            )
        val viewport = GalleryViewport()
        viewport.reset(data, 20f, 400f, 700f)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val phase = AtomicInteger(0)
        val starts = AtomicInteger()
        val cancelled = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        lateinit var bank: GalleryPreviews
        ui.runOnUiThread {
            bank =
                GalleryPreviews(ui.activity, graph, scope, { false }) { _, w, h ->
                    starts.incrementAndGet()
                    try {
                        if (phase.get() == 0) gate.await() else delay(2)
                        Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    } catch (e: CancellationException) {
                        cancelled.incrementAndGet()
                        throw e
                    }
                }
            bank.request(data, viewport.window(), 400f, 700f, 2f, 0)
        }
        try {
            ui.waitUntil(5000) { starts.get() == 4 }
            phase.set(1)
            viewport.scroll(-1600f)
            val next = viewport.window()
            ui.runOnUiThread { bank.request(data, next, 400f, 700f, 2f, 0) }
            val visible = next.tiles.filter { it.bounds.bottom > 0 && it.bounds.y < 700 }
            ui.waitUntil(15000) {
                runBlocking(Dispatchers.Main) {
                    visible.all { bank.get(data.items[it.index], 0) != null }
                }
            }
            assertEquals(4, cancelled.get())
            assertTrue(starts.get() <= visible.size + 24 + 4)
        } finally {
            ui.runOnUiThread {
                bank.close()
                scope.cancel()
            }
        }
    }
}
