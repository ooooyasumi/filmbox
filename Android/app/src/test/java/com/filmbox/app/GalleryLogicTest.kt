package com.filmbox.app

import org.junit.Assert.*
import org.junit.Test

class GalleryLogicTest {
    private fun photo(id: String = "1", w: Int = 400, h: Int = 300, mime: String = "image/jpeg") =
        Media(id, "gallery", "content://media/$id", "$id.jpg", mime, w, h)

    @Test
    fun rowUsesOriginalRatios() {
        val rows =
            justifiedRows(
                listOf(photo("a", 400, 300), photo("b", 300, 400), photo("c", 1600, 900)),
                400f,
                150f,
            )
        rows.forEach { r ->
            r.items.forEachIndexed { i, m -> assertEquals(m.ratio, r.widths[i] / r.height, .001f) }
        }
    }

    @Test
    fun completeRowsFitWidth() {
        val rows = justifiedRows((1..30).map { photo("$it") }, 400f, 150f)
        rows.dropLast(1).forEach {
            assertEquals(400f, it.widths.sum() + 3f * (it.items.size - 1), .01f)
        }
    }

    @Test
    fun lastRowDoesNotStretchSinglePhoto() {
        val row = justifiedRows(listOf(photo()), 800f, 150f).single()
        assertEquals(150f, row.height, .01f)
    }

    @Test
    fun narrowOrEmptyLayoutHasNoInvalidValues() {
        assertTrue(justifiedRows(emptyList(), 400f, 150f).isEmpty())
        assertTrue(justifiedRows(listOf(photo()), 0f, 150f).isEmpty())
        assertTrue(justifiedRows(listOf(photo(w = 0, h = 0)), 34f, 150f).single().height.isFinite())
    }

    @Test
    fun everyPhotoOccursExactlyOnce() {
        val input = (1..10000).map { photo("$it", if (it % 2 == 0) 1920 else 720, 1080) }
        assertEquals(
            input.map { it.id },
            justifiedRows(input, 430f, 160f).flatMap { it.items }.map { it.id },
        )
    }

    @Test
    fun unknownAspectIsSquare() {
        assertEquals(1f, photo(w = 0, h = 0).ratio, 0f)
    }

    @Test
    fun reelPanoramaFitsWidth() {
        assertEquals(400f, reelWidth(4f, 400f, 700f), 0f)
    }

    @Test
    fun reelPortraitFillsHeight() {
        assertEquals(350f, reelWidth(.5f, 400f, 700f), 0f)
    }

    @Test
    fun focusedPhotoIsClosestToViewportCenter() {
        assertEquals(2, focusedIndex(listOf(1 to 20f, 2 to 180f, 3 to 400f), 200f))
        assertNull(focusedIndex(emptyList(), 10f))
    }

    @Test
    fun downloadFilterNeverIncludesLocalFiles() {
        val local = photo()
        val cloud = local.copy(remoteId = "c")
        assertFalse(Filter(download = 1).matches(local, true))
        assertTrue(Filter(download = 1).matches(cloud, true))
        assertFalse(Filter(download = 1).matches(cloud, false))
        assertTrue(Filter(download = 2).matches(cloud, false))
    }

    @Test
    fun filtersCompose() {
        val cloud = photo(mime = "video/mp4").copy(name = "A.MP4", remoteId = "r")
        assertTrue(Filter(type = 2, source = 2, formats = setOf("MP4")).matches(cloud, false))
        assertFalse(Filter(type = 1, source = 2).matches(cloud, false))
    }

    @Test
    fun cacheRevisionIncludesContentChanges() {
        val m = photo()
        assertNotEquals(m.revision, m.copy(size = 7).revision)
        assertNotEquals(m.revision, m.copy(modified = 1).revision)
    }

    @Test
    fun sourceAndFormatAreIndependent() {
        assertEquals("JPEG", photo().copy(name = "hello.JPEG").format)
        assertFalse(photo().cloud)
        assertTrue(photo().copy(remoteId = "any").cloud)
    }

    @Test
    fun groupDatesRespectWeekBoundaries() {
        val mon =
            java.time.LocalDate.of(2026, 11, 9)
                .atStartOfDay(java.time.ZoneId.systemDefault())
                .toInstant()
                .toEpochMilli()
        assertEquals(groupKey(mon, 1), groupKey(mon + 2 * 86400000L, 1))
        assertNotEquals(groupKey(mon, 1), groupKey(mon - 86400000L, 1))
    }

    @Test
    fun dateWheelDensityIsGentlyWeightedAndBounded() {
        assertTrue(timelineExtent(30, true) > timelineExtent(1, true))
        assertTrue(timelineExtent(100000, true) <= 70f)
        assertTrue(timelineExtent(100000, false) <= 104f)
    }

    @Test
    fun sharedLocalMediaHasOneOrganizationIdentity() {
        val a = photo()
        assertEquals(a.identityKey, a.copy(id = "folder-copy", source = "folder").identityKey)
    }

    @Test
    fun orientationInvalidatesImageCache() {
        val m = photo()
        assertNotEquals(m.revision, m.copy(orientation = 90).revision)
    }
}
