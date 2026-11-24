package com.filmbox.app

import kotlin.math.*
import org.junit.Assert.*
import org.junit.Test

class GalleryViewportTest {
    private fun photos(n: Int) =
        List(n) { i ->
            Media(
                "p:$i",
                "gallery",
                "content://qa/$i",
                "$i.jpg",
                "image/jpeg",
                if (i % 4 == 0) 600 else 1600,
                1000,
                date = 1794268800000L - (i / 20) * 86400000L,
            )
        }

    private fun nonOverlapping(window: GalleryWindow) {
        assertEquals(window.tiles.size, window.tiles.map { it.index }.toSet().size)
        val sorted = window.tiles.sortedBy { it.bounds.y }
        for (i in sorted.indices) for (j in i + 1 until sorted.size) {
            val a = sorted[i].bounds
            val b = sorted[j].bounds
            if (b.y >= a.bottom - .01f) break
            val overlapX = min(a.right, b.right) - max(a.x, b.x)
            val overlapY = min(a.bottom, b.bottom) - max(a.y, b.y)
            assertFalse(
                "Overlapping photos ${sorted[i].index},${sorted[j].index}: $a / $b",
                overlapX > .02f && overlapY > .02f,
            )
        }
    }

    @Test
    fun viewportStaysCoveredAndNeverDrawsDuplicateOrOverlappingPhotosDuringPinch() {
        val data = GalleryData(photos(34595))
        val viewport = GalleryViewport()
        viewport.reset(data, 150f, 400f, 700f, GalleryPivot(17000, .5f, .5f, 220f, 350f, 150f))
        val pivot = viewport.anchorAt(220f, 350f)!!
        val base = viewport.density
        for (d in
            listOf(151f, 165f, 177f, 205f, 231f, 320f, 230f, 150f, 99f, 72f, 49f, 31f, 20f, 12f)) {
            viewport.reset(data, d, 400f, 700f, pivot.copy(height = pivot.height * d / base))
            val window = viewport.window()
            nonOverlapping(window)
            val anchored = window.tiles.single { it.index == pivot.index }.bounds
            assertTrue("Lost pinch center at $d: $anchored", anchored.contains(220f, 350f))
            assertTrue(window.tiles.minOf { it.bounds.y } <= 12f)
            assertTrue(window.tiles.maxOf { it.bounds.bottom } >= 700f)
            assertTrue("Whole library was laid out during gesture", window.tiles.size < 2500)
            window.tiles.forEach { tile ->
                assertEquals(
                    data.items[tile.index].ratio,
                    tile.bounds.width / tile.bounds.height,
                    .002f,
                )
            }
        }
    }

    @Test
    fun radialOrderIncludesTheWholeViewportAndOnlyABoundedPrefetchMargin() {
        val tiles =
            (-10..49).flatMap { row ->
                (0..29).map { col ->
                    GalleryTile(
                        (row + 10) * 30 + col,
                        GalleryBounds(col * 10f, row * 10f, 10f, 10f),
                    )
                }
            }
        val plan = galleryPreviewOrder(tiles, 300f, 400f)
        val visible = plan.filter { it.bounds.bottom > 0 && it.bounds.y < 400 }
        assertEquals(1200, visible.size)
        assertEquals(24, plan.size - visible.size)
        assertEquals(300, visible.first().index)
        val distances = visible.map { hypot(it.bounds.centerX, it.bounds.centerY) }
        assertEquals(distances.sorted(), distances)
    }

    @Test
    fun reflowNearLibraryStartDoesNotPushThePhotoAwayFromTheFingers() {
        val data = GalleryData(photos(5000))
        val viewport = GalleryViewport()
        viewport.reset(data, 150f, 400f, 700f)
        val pivot = viewport.anchorAt(250f, 610f)!!
        for (d in listOf(150f, 157.5f, 165f, 150f)) {
            viewport.reset(data, d, 400f, 700f, pivot.copy(height = pivot.height * d / 150))
            assertTrue(
                viewport
                    .window()
                    .tiles
                    .single { it.index == pivot.index }
                    .bounds
                    .contains(250f, 610f)
            )
            nonOverlapping(viewport.window())
        }
    }

    @Test
    fun aShortLibraryReturnsToTheTopAfterTheGestureWithoutLosingItsPhotos() {
        val data = GalleryData(photos(9))
        val viewport = GalleryViewport()
        viewport.reset(data, 150f, 400f, 700f)
        val pivot = viewport.anchorAt(200f, 350f)!!
        viewport.reset(data, 50f, 400f, 700f, pivot.copy(height = pivot.height / 3))
        val correction = viewport.edgeAdjustment()
        repeat(10) { viewport.adjust(correction / 10) }
        assertEquals(12f, viewport.window().tiles.minOf { it.bounds.y }, .01f)
        assertEquals(data.items.indices.toSet(), viewport.window().tiles.map { it.index }.toSet())
        assertEquals(0f, viewport.edgeAdjustment(), .01f)
    }

    @Test
    fun scrollingThroughEveryDensityCanReachAllPhotosAndBothLibraryEdges() {
        val data = GalleryData(photos(5000))
        val viewport = GalleryViewport()
        for (density in GalleryDensityStops) {
            viewport.reset(data, density, 400f, 700f)
            val seen = mutableSetOf<Int>()
            var steps = 0
            while (true) {
                val window = viewport.window()
                val visible = window.tiles.filter { it.bounds.bottom > 0 && it.bounds.y < 700 }
                visible.forEach {
                    seen.add(it.index)
                    assertEquals(
                        data.items[it.index].ratio,
                        it.bounds.width / it.bounds.height,
                        .002f,
                    )
                    assertTrue(it.bounds.x >= -.01f && it.bounds.right <= 400.01f)
                }
                if (viewport.scroll(-350f) == 0f) break
                assertTrue("Scrolling never reaches the end", ++steps < 10000)
            }
            assertEquals("Some photos were skipped at $density", data.items.indices.toSet(), seen)
            viewport.scroll(10000000f)
            assertTrue(viewport.window().tiles.any { it.index == 0 && it.bounds.y in 0f..12f })
        }
    }

    @Test
    fun metadataRatiosAnimateWithoutDuplicateTilesAndDateBubbleIsAlwaysPresent() {
        val old = GalleryData(photos(1000).map { it.copy(width = 0, height = 0) })
        val next = GalleryData(photos(1000), old)
        assertTrue(next.levels === old.levels)
        val viewport = GalleryViewport()
        viewport.reset(old, 80f, 400f, 700f)
        viewport.scroll(-1500f)
        val pivot = viewport.anchorAt(160f, 300f)!!
        for (step in 0..12) {
            viewport.reset(next, 80f, 400f, 700f, pivot, old.ratios, step / 12f)
            val window = viewport.window()
            nonOverlapping(window)
            assertTrue(window.dates.isNotEmpty())
            assertTrue(window.dates.first().title.contains("年"))
            assertTrue(window.tiles.single { it.index == pivot.index }.bounds.contains(160f, 300f))
        }
        for (d in GalleryDensityStops) {
            viewport.reset(next, d, 400f, 700f)
            repeat(15) {
                viewport.scroll(-450f)
                assertTrue(viewport.window().dates.isNotEmpty())
            }
        }
    }
}
