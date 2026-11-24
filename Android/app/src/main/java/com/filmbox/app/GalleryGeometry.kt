package com.filmbox.app

import kotlin.math.*

val GalleryDensityStops = floatArrayOf(12f, 20f, 32f, 50f, 80f, 115f, 150f, 230f, 360f)

fun snapGalleryDensity(value: Float) =
    GalleryDensityStops.minBy { abs(ln(value.coerceAtLeast(1f) / it)) }

fun galleryDateLevel(density: Float) =
    when {
        density < 36 -> 3
        density < 90 -> 2
        density < 150 -> 1
        else -> 0
    }
