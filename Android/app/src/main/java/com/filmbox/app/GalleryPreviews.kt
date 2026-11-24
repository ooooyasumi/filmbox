@file:OptIn(coil.annotation.ExperimentalCoilApi::class)

package com.filmbox.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.os.SystemClock
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.graphics.drawable.toBitmap
import coil.Coil
import coil.request.*
import kotlin.math.*
import kotlinx.coroutines.*

/** Four workers consume the complete visible plan; queued items do not each own a coroutine. */
internal class GalleryPreviews(
    private val context: Context,
    private val graph: AppGraph,
    private val scope: CoroutineScope,
    private val interacting: () -> Boolean,
    private val quality: (Media) -> Int = graph::previewQuality,
    private val loader: (suspend (Media, Int, Int) -> Bitmap)? = null,
) {
    class Entry(val bitmap: Bitmap, val readyAt: Long, var previous: Bitmap? = null) {
        val image = bitmap.asImageBitmap()
        val bytes
            get() = bitmap.allocationByteCount
    }

    private data class Spec(
        val media: Media,
        val key: String,
        val width: Int,
        val height: Int,
        val visible: Boolean,
    )

    private data class Failure(val attempts: Int, val retryAt: Long)

    private val cache = java.util.LinkedHashMap<String, Entry>(128, .75f, true)
    private val keys = java.util.IdentityHashMap<Media, Pair<Int, String>>()
    private val jobs = mutableMapOf<String, Job>()
    private val failures = mutableMapOf<String, Failure>()
    private var desired = emptyList<Spec>()
    private var retryJob: Job? = null
    private var fadeCleanup: Job? = null
    private var dimensionJob: Job? = null
    private val dimensions = mutableMapOf<String, Triple<Media, Int, Int>>()
    private var bytes = 0L
    private val budget =
        (Runtime.getRuntime().maxMemory() / 20).coerceIn(8L * 1024 * 1024, 24L * 1024 * 1024)
    var version by mutableIntStateOf(0)
        private set

    private var activeKeys by mutableStateOf(emptySet<String>())
    private var closed = false

    private fun key(media: Media, epoch: Int): String {
        keys[media]?.let { if (it.first == epoch) return it.second }
        val source =
            if (media.cloud) media.revision
            else "${media.uri}:${media.modified}:${media.size}:${media.orientation}"
        val key = "$source:${quality(media)}:$epoch"
        if (keys.size > 6000) keys.clear()
        keys[media] = epoch to key
        return key
    }

    private fun alternateKey(key: String): String? {
        val epoch = key.substringAfterLast(':')
        val source = key.substringBeforeLast(':').substringBeforeLast(':')
        return (2 downTo 0).firstNotNullOfOrNull { q -> "$source:$q:$epoch".takeIf { it in cache } }
    }

    private fun alternate(key: String) = alternateKey(key)?.let { cache[it] }

    fun get(media: Media, epoch: Int): Entry? {
        val key = key(media, epoch)
        return cache[key] ?: if (media.cloud) alternate(key) else null
    }

    fun failed(media: Media, epoch: Int) = failures[key(media, epoch)]?.retryAt == Long.MAX_VALUE

    fun loading(media: Media, epoch: Int) = key(media, epoch) in activeKeys

    fun request(
        data: GalleryData?,
        window: GalleryWindow,
        width: Float,
        height: Float,
        pixels: Float,
        epoch: Int,
    ) {
        if (closed) return
        val ordered =
            if (data == null) emptyList() else galleryPreviewOrder(window.tiles, width, height)
        val specs =
            ordered
                .map { tile ->
                    val m = data!!.items[tile.index]
                    Spec(
                        m,
                        key(m, epoch),
                        ceil(tile.bounds.width * pixels).toInt().coerceIn(2, 1600),
                        ceil(tile.bounds.height * pixels).toInt().coerceIn(2, 1600),
                        tile.bounds.bottom > 0 && tile.bounds.y < height,
                    )
                }
                .groupBy { it.key }
                .values
                .map { same ->
                    same
                        .first()
                        .copy(
                            width = same.maxOf { it.width },
                            height = same.maxOf { it.height },
                            visible = same.any { it.visible },
                        )
                }
        val visibleBytes = specs.filter { it.visible }.sumOf { it.width.toLong() * it.height * 4 }
        val scale = sqrt((budget * .7 / visibleBytes.coerceAtLeast(1)).coerceAtMost(1.0)).toFloat()
        desired =
            specs.map {
                it.copy(
                    width = (it.width * scale).roundToInt().coerceAtLeast(2),
                    height = (it.height * scale).roundToInt().coerceAtLeast(2),
                )
            }
        val wanted = desired.map { it.key }.toSet()
        jobs.filterKeys { it !in wanted }.values.toList().forEach { it.cancel() }
        trim()
        pump()
    }

    private fun enough(spec: Spec, entry: Entry): Boolean {
        val requested = max(spec.width, spec.height)
        val available = max(entry.bitmap.width, entry.bitmap.height)
        // An upgrade need not repeatedly re-decode a provider's small source image.
        return available >= requested * .85f ||
            sourceLimits[spec.key]?.let { it >= requested } == true
    }

    private val sourceLimits = mutableMapOf<String, Int>()

    private fun pump() {
        if (closed) return
        retryJob?.cancel()
        retryJob = null
        val now = SystemClock.uptimeMillis()
        while (jobs.size < 4) {
            val next =
                desired.firstOrNull { spec ->
                    if (spec.key in jobs) false
                    else if (failures[spec.key]?.retryAt?.let { it > now } == true) false
                    else
                        cache[spec.key]?.let { entry ->
                            !enough(spec, entry) ||
                                bytes > budget &&
                                    entry.bytes > spec.width.toLong() * spec.height * 8
                        } ?: true
                } ?: break
            val job = scope.launch(start = CoroutineStart.LAZY) { load(next) }
            jobs[next.key] = job
            // Cancellation can happen before the coroutine body starts. Its finally block
            // would never run, leaving a worker slot occupied forever.
            job.invokeOnCompletion {
                scope.launch {
                    yield()
                    if (!closed && jobs[next.key] === job) {
                        jobs.remove(next.key)
                        pump()
                    }
                }
            }
            job.start()
        }
        val nextRetry =
            desired
                .mapNotNull { failures[it.key]?.retryAt }
                .filter { it != Long.MAX_VALUE && it > now }
                .minOrNull()
        if (nextRetry != null)
            retryJob =
                scope.launch {
                    delay((nextRetry - SystemClock.uptimeMillis()).coerceAtLeast(1))
                    pump()
                }
        activeKeys = jobs.keys.toSet()
    }

    private suspend fun load(spec: Spec) {
        try {
            val existing = cache[spec.key]
            val bitmap =
                if (loader != null) loader.invoke(spec.media, spec.width, spec.height)
                else if (
                    existing != null &&
                        enough(spec, existing) &&
                        existing.bytes > spec.width.toLong() * spec.height * 8
                ) {
                    withContext(Dispatchers.Default) {
                        resized(existing.bitmap, spec.width, spec.height)
                    }
                } else
                    nativeThumbnail(spec.media, spec.width, spec.height)
                        ?: run {
                            val model = graph.preview(spec.media)
                            val request =
                                ImageRequest.Builder(context)
                                    .data(model)
                                    .size(spec.width, spec.height)
                                    .precision(coil.size.Precision.EXACT)
                                    .bitmapConfig(Bitmap.Config.ARGB_8888)
                                    .allowHardware(false)
                                    .memoryCachePolicy(CachePolicy.DISABLED)
                                    .diskCacheKey("preview:${spec.media.revision}")
                                    .build()
                            val result = Coil.imageLoader(context).execute(request)
                            if (result !is SuccessResult) throw (result as ErrorResult).throwable
                            (result.drawable as? BitmapDrawable)?.bitmap
                                ?: withContext(Dispatchers.Default) { result.drawable.toBitmap() }
                        }
            currentCoroutineContext().ensureActive()
            sourceLimits[spec.key] = max(spec.width, spec.height)
            val exact = cache.remove(spec.key)
            bytes -= exact?.bytes ?: 0
            val previous = exact ?: if (spec.media.cloud) alternate(spec.key) else null
            val preserveFade =
                exact != null &&
                    max(bitmap.width, bitmap.height) <= max(exact.bitmap.width, exact.bitmap.height)
            cache[spec.key] =
                Entry(
                    bitmap,
                    if (preserveFade) previous!!.readyAt else SystemClock.uptimeMillis(),
                    if (preserveFade) null else previous?.bitmap,
                )
            bytes += bitmap.allocationByteCount
            failures.remove(spec.key)
            if (spec.media.width <= 0 && bitmap.width > 0 && bitmap.height > 0) {
                val size = previewDimensions(spec.media) ?: (bitmap.width to bitmap.height)
                dimensions[spec.media.id] = Triple(spec.media, size.first, size.second)
                if (dimensionJob?.isActive != true)
                    dimensionJob =
                        scope.launch {
                            while (dimensions.isNotEmpty()) {
                                delay(600)
                                if (!interacting()) {
                                    val batch = dimensions.values.toList()
                                    dimensions.clear()
                                    graph.updatePreviewDimensions(batch)
                                }
                            }
                        }
            }
            trim()
            version++
            fadeCleanup?.cancel()
            fadeCleanup =
                scope.launch {
                    delay(240)
                    cache.values.forEach { it.previous = null }
                }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val old = failures[spec.key]?.attempts ?: 0
            val recover = RecoveryProblem.from(e, true).automaticRetry && old == 0
            failures[spec.key] =
                Failure(old + 1, if (recover) SystemClock.uptimeMillis() + 1000 else Long.MAX_VALUE)
            version++
        }
    }

    private suspend fun previewDimensions(media: Media): Pair<Int, Int>? =
        withContext(Dispatchers.IO) {
            runCatching {
                    val options =
                        android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    if (media.cloud) {
                        Coil.imageLoader(context)
                            .diskCache
                            ?.openSnapshot("preview:${media.revision}")
                            ?.use {
                                android.graphics.BitmapFactory.decodeFile(
                                    it.data.toFile().path,
                                    options,
                                )
                            }
                    } else
                        context.contentResolver
                            .openInputStream(android.net.Uri.parse(media.uri))
                            ?.use { android.graphics.BitmapFactory.decodeStream(it, null, options) }
                    if (options.outWidth > 0 && options.outHeight > 0) {
                        if (!media.cloud && media.orientation % 180 != 0)
                            options.outHeight to options.outWidth
                        else options.outWidth to options.outHeight
                    } else null
                }
                .getOrNull()
        }

    private fun resized(bitmap: Bitmap, width: Int, height: Int): Bitmap {
        val scale =
            min(width.toFloat() / bitmap.width, height.toFloat() / bitmap.height).coerceAtMost(1f)
        return Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * scale).roundToInt().coerceAtLeast(1),
            (bitmap.height * scale).roundToInt().coerceAtLeast(1),
            true,
        )
    }

    private suspend fun nativeThumbnail(media: Media, width: Int, height: Int): Bitmap? {
        val uri = android.net.Uri.parse(media.uri)
        if (
            media.cloud ||
                !media.dimensionsVerified ||
                max(width, height) > 192 ||
                uri.authority != android.provider.MediaStore.AUTHORITY
        )
            return null
        return withContext(Dispatchers.IO) {
            coroutineScope {
                val signal = android.os.CancellationSignal()
                val cancel =
                    launch(start = CoroutineStart.UNDISPATCHED) {
                        try {
                            awaitCancellation()
                        } finally {
                            signal.cancel()
                        }
                    }
                try {
                    resized(
                        context.contentResolver.loadThumbnail(
                            uri,
                            android.util.Size(width, height),
                            signal,
                        ),
                        width,
                        height,
                    )
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    currentCoroutineContext().ensureActive()
                    null
                } finally {
                    cancel.cancel()
                }
            }
        }
    }

    private fun trim() {
        val visible = desired.filter { it.visible }.map { it.key }.toMutableSet()
        // Keep the lower-quality image on screen until its replacement has decoded.
        desired
            .filter { it.visible && it.media.cloud && it.key !in cache }
            .forEach { spec -> alternateKey(spec.key)?.let { visible.add(it) } }
        val remove = cache.entries.filter { it.key !in visible }.map { it.key }
        for (key in remove) {
            if (bytes <= budget && cache.size <= max(3000, visible.size)) break
            cache.remove(key)?.let { bytes -= it.bytes }
            sourceLimits.remove(key)
        }
        val now = SystemClock.uptimeMillis()
        cache.values.forEach { if (now - it.readyAt > 220) it.previous = null }
        if (failures.size > 6000) {
            val keep = desired.map { it.key }.toSet()
            failures.keys.retainAll(keep)
        }
    }

    fun resetFailures() {
        failures.clear()
        keys.clear()
        pump()
    }

    fun close() {
        closed = true
        fadeCleanup?.cancel()
        retryJob?.cancel()
        dimensionJob?.cancel()
        jobs.values.toList().forEach { it.cancel() }
        jobs.clear()
        activeKeys = emptySet()
        cache.clear()
        sourceLimits.clear()
        bytes = 0
    }
}
