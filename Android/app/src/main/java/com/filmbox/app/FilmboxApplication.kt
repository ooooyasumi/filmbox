package com.filmbox.app

import android.app.Application
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.decode.VideoFrameDecoder
import coil.disk.DiskCache
import coil.memory.MemoryCache

class FilmboxApplication : Application(), ImageLoaderFactory {
    val graph by lazy { AppGraph(this) }

    override fun newImageLoader() =
        ImageLoader.Builder(this)
            .memoryCache { MemoryCache.Builder(this).maxSizePercent(.12).build() }
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("previews"))
                    .maxSizeBytes(256L * 1024 * 1024)
                    .build()
            }
            .components { add(VideoFrameDecoder.Factory()) }
            .okHttpClient { graph.cloud.http }
            .crossfade(180)
            .respectCacheHeaders(false)
            .build()

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_RUNNING_LOW) coil.Coil.imageLoader(this).memoryCache?.clear()
    }
}
