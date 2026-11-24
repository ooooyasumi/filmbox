package com.filmbox.app

import org.junit.Assert.*
import org.junit.Test

class GalleryGeometryTest {
    @Test
    fun densityStopsCoverOverviewAndSnapByScale() {
        assertEquals(12f, snapGalleryDensity(1f), 0f)
        assertEquals(360f, snapGalleryDensity(1000f), 0f)
        assertEquals(150f, snapGalleryDensity(160f), 0f)
        assertEquals(3, galleryDateLevel(12f))
        assertEquals(0, galleryDateLevel(360f))
        assertEquals(2, galleryDateLevel(50f))
        assertEquals(1, galleryDateLevel(115f))
    }
}
