@file:OptIn(coil.annotation.ExperimentalCoilApi::class)

package com.filmbox.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import androidx.work.WorkInfo
import androidx.work.WorkManager
import coil.Coil
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import okhttp3.Request
import org.json.JSONArray

data class GalleryState(
    val items: List<Media> = emptyList(),
    val libraries: List<Library> = emptyList(),
    val albums: List<Album> = emptyList(),
    val scanning: Map<String, Int> = emptyMap(),
    val indexing: Map<String, IndexProgress> = emptyMap(),
    val problems: Map<String, String> = emptyMap(),
    val issues: Map<String, RecoveryProblem> = emptyMap(),
    val downloads: Int = 0,
    val originalTransfers: Set<String> = emptySet(),
    val cacheRevision: Int = 0,
    val cacheEpoch: Int = 0,
    val theme: String = "system",
    val ignoreHidden: Boolean = true,
    val autoplay: Boolean = true,
    val permission: Boolean = false,
    val partial: Boolean = false,
)

class AppGraph(val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val db = MediaDatabase(context)
    val indexer = LocalIndexer(context)
    val cloud = CloudEngine(context)
    val cloudIndex = CloudIndexStore(context)
    val cloudScanSlots = Semaphore(2)
    private val prefs = context.getSharedPreferences("filmbox", Context.MODE_PRIVATE)
    private val state = MutableStateFlow(GalleryState())
    val ui: StateFlow<GalleryState> = state
    private var galleryReady = false
    private var permissionSignature = ""
    private var mediaChange: Job? = null
    private val legacyIndexRecovery = mutableSetOf<String>()
    private val pendingRefresh = mutableSetOf<String>()
    private val refreshJobs = mutableMapOf<String, Job>()
    private val originals = File(context.cacheDir, "originals").apply { mkdirs() }
    private val posters = File(context.cacheDir, "posters").apply { mkdirs() }
    private val cacheMutex = Mutex()

    private data class DownloadGate(val mutex: Mutex = Mutex(), var users: Int = 0)

    private val gateMutex = Mutex()
    private val downloadGates = mutableMapOf<String, DownloadGate>()
    @Volatile private var cachedOriginals: Map<String, File> = emptyMap()
    @Volatile private var cachedPosters: Set<String> = emptySet()

    fun isDownloaded(m: Media) = m.cloud && m.revision in cachedOriginals

    fun previewQuality(m: Media) =
        if (m.revision in cachedPosters) 2 else if (isDownloaded(m)) 1 else 0

    private fun rebuildCacheIndex(items: List<Media>) {
        val files =
            originals
                .listFiles()
                ?.filter { it.extension != "part" }
                ?.associateBy { it.nameWithoutExtension } ?: emptyMap()
        val frames = posters.listFiles()?.map { it.nameWithoutExtension }?.toSet() ?: emptySet()
        val originalsByRevision = mutableMapOf<String, File>()
        val postersByRevision = mutableSetOf<String>()
        if (files.isNotEmpty() || frames.isNotEmpty())
            items
                .filter { it.cloud }
                .forEach { m ->
                    val key = stem(m)
                    files[key]?.let { originalsByRevision[m.revision] = it }
                    if (key in frames) postersByRevision.add(m.revision)
                }
        cachedOriginals = originalsByRevision
        cachedPosters = postersByRevision
    }

    init {
        val libs =
            runCatching {
                    val a = JSONArray(prefs.getString("libraries", "[]"))
                    (0 until a.length()).map { Library.read(a.getJSONObject(it)) }
                }
                .getOrDefault(emptyList())
        state.value =
            state.value.copy(
                libraries = libs,
                theme = prefs.getString("theme", "system")!!,
                ignoreHidden = prefs.getBoolean("ignoreHidden", true),
                autoplay = prefs.getBoolean("autoplay", true),
            )
        cloud.onProblem = { account, issue ->
            state.update { s ->
                val ids = s.libraries.filter { it.account == account }.map { it.id }.toSet()
                s.copy(
                    problems =
                        (s.problems - ids) +
                            if (issue != null) ids.associateWith { issue.title } else emptyMap(),
                    issues =
                        (s.issues - ids) +
                            if (issue != null) ids.associateWith { issue } else emptyMap(),
                )
            }
        }
        val connectivity = context.getSystemService(android.net.ConnectivityManager::class.java)
        connectivity.registerDefaultNetworkCallback(
            object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) {
                    scope.launch { recoverNetwork() }
                }
            }
        )
        cloud.accountForSource = { source ->
            state.value.libraries.firstOrNull { it.id == source }?.account ?: source
        }
        context.contentResolver.registerContentObserver(
            android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            true,
            object :
                android.database.ContentObserver(
                    android.os.Handler(android.os.Looper.getMainLooper())
                ) {
                override fun onChange(selfChange: Boolean) {
                    mediaChange?.cancel()
                    mediaChange =
                        scope.launch {
                            delay(600)
                            refreshGallery()
                        }
                }
            },
        )
        context.contentResolver.registerContentObserver(
            android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            true,
            object :
                android.database.ContentObserver(
                    android.os.Handler(android.os.Looper.getMainLooper())
                ) {
                override fun onChange(selfChange: Boolean) {
                    mediaChange?.cancel()
                    mediaChange =
                        scope.launch {
                            delay(600)
                            refreshGallery()
                        }
                }
            },
        )
        scope.launch {
            WorkManager.getInstance(context).getWorkInfosByTagFlow(CloudIndexWorker.TAG).collect {
                jobs ->
                val latest =
                    jobs
                        .groupBy {
                            it.tags
                                .firstOrNull { tag -> tag.startsWith("source:") }
                                ?.removePrefix("source:")
                        }
                        .mapValues { (_, works) ->
                            works.maxBy { w ->
                                w.tags
                                    .firstOrNull { it.startsWith("created:") }
                                    ?.removePrefix("created:")
                                    ?.toLongOrNull() ?: 0L
                            }
                        }
                val cloudIds = state.value.libraries.filter { it.cloud }.map { it.id }.toSet()
                val active =
                    latest.filter { (id, work) -> id in cloudIds && !work.state.isFinished }
                val progress =
                    withContext(Dispatchers.IO) {
                        active
                            .mapNotNull { (id, work) ->
                                id?.let {
                                    it to
                                        cloudIndex
                                            .progress(it)
                                            .copy(running = work.state == WorkInfo.State.RUNNING)
                                }
                            }
                            .toMap()
                    }
                state.update { current ->
                    current.copy(
                        indexing = progress,
                        scanning =
                            current.scanning.filterKeys { it !in cloudIds } +
                                progress.mapValues { it.value.found },
                        problems =
                            (current.problems -
                                latest
                                    .filterValues { it.state == WorkInfo.State.SUCCEEDED }
                                    .keys
                                    .filterNotNull()) +
                                latest
                                    .mapNotNull { (id, work) ->
                                        val code =
                                            work.outputData.getString("errorCode")
                                                ?: work.progress.getString("errorCode")
                                        if (
                                            id in cloudIds &&
                                                code != null &&
                                                work.state != WorkInfo.State.SUCCEEDED
                                        )
                                            id!! to RecoveryProblem.code(code).title
                                        else null
                                    }
                                    .toMap(),
                        issues =
                            (current.issues -
                                latest
                                    .filterValues { it.state == WorkInfo.State.SUCCEEDED }
                                    .keys
                                    .filterNotNull()) +
                                latest
                                    .mapNotNull { (id, work) ->
                                        val code =
                                            work.outputData.getString("errorCode")
                                                ?: work.progress.getString("errorCode")
                                        if (
                                            id in cloudIds &&
                                                code != null &&
                                                work.state != WorkInfo.State.SUCCEEDED
                                        )
                                            id!! to RecoveryProblem.code(code)
                                        else null
                                    }
                                    .toMap(),
                    )
                }
                latest.forEach { (id, work) ->
                    if (
                        id != null &&
                            id in cloudIds &&
                            work.state == WorkInfo.State.FAILED &&
                            work.outputData.getString("errorCode") == null &&
                            legacyIndexRecovery.add(id)
                    ) {
                        refresh(id)
                    }
                }
            }
        }
        scope.launch {
            withContext(Dispatchers.IO) {
                originals.listFiles()?.filter { it.extension == "part" }?.forEach { it.delete() }
            }
            reload()
            refreshGallery()
        }
    }

    fun hasMediaPermission(): Boolean {
        fun granted(p: String) =
            ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
        return if (Build.VERSION.SDK_INT >= 33)
            granted(Manifest.permission.READ_MEDIA_IMAGES) ||
                granted(Manifest.permission.READ_MEDIA_VIDEO) ||
                (Build.VERSION.SDK_INT >= 34 &&
                    granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
        else granted(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    fun onResume() {
        val allowed = hasMediaPermission()
        val partial =
            Build.VERSION.SDK_INT >= 34 &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
                ) == PackageManager.PERMISSION_GRANTED &&
                (ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.READ_MEDIA_IMAGES,
                ) != PackageManager.PERMISSION_GRANTED ||
                    ContextCompat.checkSelfPermission(
                        context,
                        Manifest.permission.READ_MEDIA_VIDEO,
                    ) != PackageManager.PERMISSION_GRANTED)
        val signature =
            (if (Build.VERSION.SDK_INT >= 33)
                    listOf(
                        Manifest.permission.READ_MEDIA_IMAGES,
                        Manifest.permission.READ_MEDIA_VIDEO,
                    )
                else listOf(Manifest.permission.READ_EXTERNAL_STORAGE))
                .joinToString { ContextCompat.checkSelfPermission(context, it).toString() }
        val invalidate = partial || signature != permissionSignature
        permissionSignature = signature
        if (invalidate) galleryReady = false
        state.update {
            it.copy(
                permission = allowed,
                partial = partial,
                items = if (invalidate) it.items.filter { m -> m.source != "gallery" } else it.items,
            )
        }
        refreshGallery()
    }

    suspend fun reload() {
        val allowed = hasMediaPermission()
        val snapshot =
            withContext(Dispatchers.IO) {
                val media =
                    db.read(
                        (state.value.libraries.map { it.id } +
                                if (allowed && galleryReady) listOf("gallery") else emptyList())
                            .toSet()
                    )
                cacheMutex.withLock { rebuildCacheIndex(media) }
                media to db.albums()
            }
        state.update {
            it.copy(items = snapshot.first, albums = snapshot.second, permission = allowed)
        }
    }

    var onRecovery: (RecoveryRequest) -> Unit = {}

    fun recover(problem: RecoveryProblem, source: String, media: Media? = null) =
        onRecovery(RecoveryRequest(problem, source, media))

    fun problem(error: Throwable?, media: Media): RecoveryProblem =
        state.value.issues[media.source] ?: RecoveryProblem.from(error, media.cloud)

    fun recoverNetwork() {
        state.value.libraries
            .filter { state.value.issues[it.id]?.automaticRetry == true }
            .forEach { refresh(it.id) }
    }

    fun refreshGallery() = refresh("gallery")

    fun refreshAll() {
        refreshGallery()
        state.value.libraries.forEach { refresh(it.id) }
    }

    fun refresh(id: String) {
        if (refreshJobs[id]?.isActive == true) {
            pendingRefresh.add(id)
            return
        }
        if (id == "gallery" && !hasMediaPermission()) {
            scope.launch { reload() }
            return
        }
        val lib = state.value.libraries.firstOrNull { it.id == id }
        if (id != "gallery" && lib == null) return
        if (lib?.cloud == true) {
            cloud.allowRecovery(lib.account)
            state.update { it.copy(problems = it.problems - id, issues = it.issues - id) }
            CloudIndexWorker.enqueue(context, id)
            return
        }
        refreshJobs[id] =
            scope
                .launch {
                    state.update {
                        it.copy(
                            scanning = it.scanning + (id to 0),
                            problems = it.problems - id,
                            issues = it.issues - id,
                        )
                    }
                    try {
                        val items =
                            withContext(Dispatchers.IO) {
                                when {
                                    id == "gallery" -> indexer.gallery(state.value.ignoreHidden)
                                    lib!!.cloud ->
                                        cloud.scan(lib, state.value.ignoreHidden) { count ->
                                            state.update {
                                                it.copy(scanning = it.scanning + (id to count))
                                            }
                                        }
                                    else -> indexer.folder(lib, state.value.ignoreHidden)
                                }
                            }
                        ensureActive()
                        withContext(Dispatchers.IO) { db.replace(id, items) }
                        if (id == "gallery") galleryReady = true
                        reload()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        val issue =
                            if (e is SecurityException) RecoveryProblem.PERMISSION
                            else if (lib?.cloud != true) RecoveryProblem.OFFLINE
                            else RecoveryProblem.from(e, true)
                        state.update {
                            it.copy(
                                problems = it.problems + (id to issue.title),
                                issues = it.issues + (id to issue),
                            )
                        }
                    } finally {
                        state.update { it.copy(scanning = it.scanning - id) }
                    }
                }
                .also { job ->
                    job.invokeOnCompletion {
                        scope.launch { if (pendingRefresh.remove(id)) refresh(id) }
                    }
                }
    }

    fun reconnectFolder(id: String, uri: Uri) {
        state.update { s ->
            s.copy(
                libraries =
                    s.libraries.map { if (it.id == id) it.copy(uri = uri.toString()) else it }
            )
        }
        saveLibraries()
        refresh(id)
    }

    fun addFolder(uri: Uri) {
        val existing = state.value.libraries.firstOrNull { it.uri == uri.toString() }
        if (existing != null) {
            refresh(existing.id)
            return
        }
        val name =
            runCatching {
                    context.contentResolver
                        .query(
                            DocumentsContractCompat.root(uri),
                            arrayOf("_display_name"),
                            null,
                            null,
                            null,
                        )
                        ?.use { if (it.moveToFirst()) it.getString(0) else null }
                }
                .getOrNull() ?: "文件夹"
        addLibrary(Library(UUID.randomUUID().toString(), name, uri.toString()))
    }

    fun addLibrary(library: Library) {
        state.update { it.copy(libraries = it.libraries + library) }
        saveLibraries()
        refresh(library.id)
    }

    fun renameLibrary(id: String, name: String) {
        state.update {
            it.copy(
                libraries = it.libraries.map { l -> if (l.id == id) l.copy(name = name) else l }
            )
        }
        saveLibraries()
    }

    fun moveLibrary(id: String, delta: Int) {
        state.update { s ->
            val list = s.libraries.toMutableList()
            val i = list.indexOfFirst { it.id == id }
            if (i >= 0) {
                val l = list.removeAt(i)
                list.add((i + delta).coerceIn(0, list.size), l)
            }
            s.copy(libraries = list)
        }
        saveLibraries()
    }

    fun removeLibrary(id: String) {
        refreshJobs.remove(id)?.cancel()
        WorkManager.getInstance(context).cancelUniqueWork(CloudIndexWorker.name(id))
        scope.launch(Dispatchers.IO) { cloudIndex.clear(id) }
        state.update {
            it.copy(
                libraries = it.libraries.filterNot { l -> l.id == id },
                items = it.items.filterNot { m -> m.source == id },
                problems = it.problems - id,
                issues = it.issues - id,
                indexing = it.indexing - id,
                scanning = it.scanning - id,
            )
        }
        saveLibraries()
        scope.launch(Dispatchers.IO) { db.removeSource(id) }
    }

    private fun saveLibraries() {
        prefs
            .edit()
            .putString("libraries", JSONArray(state.value.libraries.map { it.json() }).toString())
            .apply()
    }

    private fun identities(ids: Set<String>) =
        state.value.items.filter { it.id in ids }.map { it.identityKey }.toSet()

    fun mark(ids: Set<String>, favorite: Boolean? = null, hidden: Boolean? = null) {
        scope.launch {
            withContext(Dispatchers.IO) { db.mark(identities(ids), favorite, hidden) }
            reload()
        }
    }

    fun createAlbum(name: String, ids: Set<String> = emptySet()) {
        scope.launch {
            withContext(Dispatchers.IO) {
                val id = db.addAlbum(name)
                db.membership(id, identities(ids), true)
            }
            reload()
        }
    }

    fun albumAdd(album: String, ids: Set<String>, add: Boolean = true) {
        scope.launch {
            withContext(Dispatchers.IO) { db.membership(album, identities(ids), add) }
            reload()
        }
    }

    fun renameAlbum(id: String, name: String) {
        scope.launch {
            withContext(Dispatchers.IO) { db.renameAlbum(id, name) }
            reload()
        }
    }

    fun deleteAlbum(id: String) {
        scope.launch {
            withContext(Dispatchers.IO) { db.deleteAlbum(id) }
            reload()
        }
    }

    fun settings(theme: String? = null, ignoreHidden: Boolean? = null, autoplay: Boolean? = null) {
        state.update {
            it.copy(
                theme = theme ?: it.theme,
                ignoreHidden = ignoreHidden ?: it.ignoreHidden,
                autoplay = autoplay ?: it.autoplay,
            )
        }
        prefs
            .edit()
            .putString("theme", state.value.theme)
            .putBoolean("ignoreHidden", state.value.ignoreHidden)
            .putBoolean("autoplay", state.value.autoplay)
            .apply()
        if (ignoreHidden != null) refreshAll()
    }

    private fun stem(m: Media) = cacheHash(m.revision)

    private fun cacheHash(revision: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(revision.toByteArray())
        val hex = "0123456789abcdef"
        val chars = CharArray(bytes.size * 2)
        bytes.forEachIndexed { i, b ->
            val value = b.toInt() and 255
            chars[i * 2] = hex[value ushr 4]
            chars[i * 2 + 1] = hex[value and 15]
        }
        return String(chars)
    }

    fun original(m: Media): File? = cachedOriginals[m.revision]

    fun poster(m: Media): File? = File(posters, stem(m) + ".jpg").takeIf { it.isFile }

    suspend fun preview(m: Media): Any {
        withContext(Dispatchers.IO) { poster(m) }
            ?.let {
                return it
            }
        original(m)?.let { file ->
            withContext(Dispatchers.IO) {
                if (System.currentTimeMillis() - file.lastModified() > 60000)
                    file.setLastModified(System.currentTimeMillis())
            }
            return file
        }
        if (m.cloud)
            withContext(Dispatchers.IO) {
                    Coil.imageLoader(context)
                        .diskCache
                        ?.openSnapshot("preview:${m.revision}")
                        ?.use { it.data.toFile() }
                }
                ?.let {
                    return it
                }
        if (m.cloud && state.value.issues[m.source] == RecoveryProblem.LOGIN)
            throw CloudFailure("authentication_expired")
        return if (m.cloud) cloud.resolve(m, "thumbnail") else Uri.parse(m.uri)
    }

    /**
     * Only an explicit viewer/focused reel requests an original. A canceled focus deletes its
     * partial file.
     */
    suspend fun download(m: Media): File {
        require(m.cloud) { "本地文件无需下载" }
        val gate =
            gateMutex.withLock {
                downloadGates.getOrPut(m.revision) { DownloadGate() }.also { it.users++ }
            }
        try {
            return gate.mutex.withLock { downloadOriginal(m) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            cloud.report(cloud.accountForSource(m.source), RecoveryProblem.from(e, true))
            throw e
        } finally {
            withContext(NonCancellable) {
                gateMutex.withLock {
                    gate.users--
                    if (gate.users == 0) downloadGates.remove(m.revision)
                }
            }
        }
    }

    private suspend fun downloadOriginal(m: Media): File {
        original(m)?.let {
            it.setLastModified(System.currentTimeMillis())
            return it
        }
        state.update {
            it.copy(
                downloads = it.downloads + 1,
                originalTransfers = it.originalTransfers + m.revision,
            )
        }
        var transferring = true
        fun finishTransfer() {
            if (transferring) {
                transferring = false
                state.update {
                    it.copy(
                        downloads = (it.downloads - 1).coerceAtLeast(0),
                        originalTransfers = it.originalTransfers - m.revision,
                    )
                }
            }
        }
        val temporary = File(originals, UUID.randomUUID().toString() + ".part")
        try {
            val url = cloud.resolve(m, "original")
            val call = cloud.http.newCall(Request.Builder().url(url).build())
            withContext(Dispatchers.IO) {
                coroutineScope {
                    val cancel =
                        launch(start = CoroutineStart.UNDISPATCHED) {
                            try {
                                awaitCancellation()
                            } finally {
                                call.cancel()
                            }
                        }
                    try {
                        call.await().use { res ->
                            if (!res.isSuccessful)
                                throw cloud.responseFailure(res, cloud.accountForSource(m.source))
                            res.body!!.byteStream().use { input ->
                                temporary.outputStream().use { output ->
                                    val buffer = ByteArray(64 * 1024)
                                    while (true) {
                                        ensureActive()
                                        val n = input.read(buffer)
                                        if (n < 0) break
                                        output.write(buffer, 0, n)
                                    }
                                }
                            }
                            val expected = res.body!!.contentLength()
                            if (expected >= 0 && temporary.length() != expected)
                                throw CloudFailure("incomplete")
                        }
                    } finally {
                        cancel.cancel()
                    }
                }
            }
            currentCoroutineContext().ensureActive()
            val destination = File(originals, stem(m) + "." + m.format.lowercase())
            withContext(Dispatchers.IO) {
                cacheMutex.withLock {
                    if (!temporary.renameTo(destination)) error("无法保存")
                    trimOriginals(destination)
                    cachedOriginals =
                        cachedOriginals.filterValues { it.isFile } + (m.revision to destination)
                }
            }
            finishTransfer()
            state.update { it.copy(cacheRevision = it.cacheRevision + 1) }
            makePoster(m, destination)
            withContext(Dispatchers.IO) {
                cacheMutex.withLock {
                    cachedPosters =
                        cachedPosters
                            .filter { File(posters, cacheHash(it) + ".jpg").isFile }
                            .toSet() + if (poster(m) != null) setOf(m.revision) else emptySet()
                }
            }
            state.update { it.copy(cacheRevision = it.cacheRevision + 1) }
            return destination
        } finally {
            temporary.delete()
            finishTransfer()
        }
    }

    suspend fun makePoster(m: Media, file: File) =
        withContext(Dispatchers.IO) {
            runCatching {
                val bitmap =
                    if (m.video)
                        MediaMetadataRetriever().let { r ->
                            try {
                                r.setDataSource(file.absolutePath)
                                r.getScaledFrameAtTime(
                                    0,
                                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                                    1280,
                                    720,
                                )
                            } finally {
                                r.release()
                            }
                        }
                    else
                        android.graphics.BitmapFactory.Options().let { o ->
                            o.inJustDecodeBounds = true
                            android.graphics.BitmapFactory.decodeFile(file.absolutePath, o)
                            o.inSampleSize = maxOf(1, maxOf(o.outWidth, o.outHeight) / 1600)
                            o.inJustDecodeBounds = false
                            android.graphics.BitmapFactory.decodeFile(file.absolutePath, o)
                        }
                bitmap?.let { b ->
                    val degrees =
                        if (m.video) 0
                        else runCatching { ExifInterface(file).rotationDegrees }.getOrDefault(0)
                    val output =
                        if (degrees != 0)
                            Bitmap.createBitmap(
                                b,
                                0,
                                0,
                                b.width,
                                b.height,
                                android.graphics.Matrix().apply { postRotate(degrees.toFloat()) },
                                true,
                            )
                        else b
                    File(posters, stem(m) + ".jpg").outputStream().use {
                        output.compress(Bitmap.CompressFormat.JPEG, 90, it)
                    }
                    if (output !== b) output.recycle()
                    b.recycle()
                }
            }
        }

    fun streaming(delta: Int) {
        state.update { it.copy(downloads = (it.downloads + delta).coerceAtLeast(0)) }
    }

    private fun trimOriginals(keep: File) {
        var size = originals.listFiles()?.sumOf { it.length() } ?: 0
        originals
            .listFiles()
            ?.filter { it != keep && it.extension != "part" }
            ?.sortedBy { it.lastModified() }
            ?.forEach { f ->
                if (size > 2L * 1024 * 1024 * 1024) {
                    size -= f.length()
                    f.delete()
                }
            }
        var psize = posters.listFiles()?.sumOf { it.length() } ?: 0
        posters
            .listFiles()
            ?.sortedBy { it.lastModified() }
            ?.forEach { f ->
                if (psize > 256L * 1024 * 1024) {
                    psize -= f.length()
                    f.delete()
                }
            }
    }

    suspend fun cacheSize(): Pair<Long, Long> =
        withContext(Dispatchers.IO) {
            (originals.listFiles()?.sumOf { it.length() } ?: 0) to
                ((posters.listFiles()?.sumOf { it.length() } ?: 0) +
                    (Coil.imageLoader(context).diskCache?.size ?: 0))
        }

    suspend fun clearCache(original: Boolean, preview: Boolean) {
        check(state.value.downloads == 0 && gateMutex.withLock { downloadGates.isEmpty() }) {
            "请等待下载完成"
        }
        withContext(Dispatchers.IO) {
            cacheMutex.withLock {
                if (original) {
                    originals.listFiles()?.forEach { it.delete() }
                    cachedOriginals = emptyMap()
                }
                if (preview) {
                    cachedPosters = emptySet()
                    posters.listFiles()?.forEach { it.delete() }
                    Coil.imageLoader(context).diskCache?.clear()
                    Coil.imageLoader(context).memoryCache?.clear()
                }
            }
        }
        state.update {
            it.copy(cacheRevision = it.cacheRevision + 1, cacheEpoch = it.cacheEpoch + 1)
        }
    }

    suspend fun originalDimensions(m: Media): Pair<Int, Int>? {
        if (m.dimensionsVerified && m.width > 0 && m.height > 0) return m.width to m.height
        val uri =
            if (m.cloud) original(m)?.let { Uri.fromFile(it) } ?: return null else Uri.parse(m.uri)
        val size =
            withContext(Dispatchers.IO) {
                runCatching {
                        if (m.video) {
                            val r = MediaMetadataRetriever()
                            try {
                                r.setDataSource(context, uri)
                                val w =
                                    r.extractMetadata(
                                            MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH
                                        )
                                        ?.toIntOrNull() ?: 0
                                val h =
                                    r.extractMetadata(
                                            MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT
                                        )
                                        ?.toIntOrNull() ?: 0
                                val angle =
                                    r.extractMetadata(
                                            MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION
                                        )
                                        ?.toIntOrNull() ?: 0
                                if (angle % 180 != 0) h to w else w to h
                            } finally {
                                r.release()
                            }
                        } else {
                            val bounds =
                                android.graphics.BitmapFactory.Options().apply {
                                    inJustDecodeBounds = true
                                }
                            context.contentResolver.openInputStream(uri)?.use {
                                android.graphics.BitmapFactory.decodeStream(it, null, bounds)
                            }
                            val rotation =
                                runCatching {
                                        context.contentResolver.openInputStream(uri)?.use {
                                            ExifInterface(it).rotationDegrees
                                        } ?: 0
                                    }
                                    .getOrDefault(0)
                            if (rotation % 180 != 0) bounds.outHeight to bounds.outWidth
                            else bounds.outWidth to bounds.outHeight
                        }
                    }
                    .getOrNull()
            }
        if (size != null && size.first > 0 && size.second > 0) {
            updateDimensions(m, size.first, size.second, true)
            return size
        }
        return null
    }

    suspend fun updatePreviewDimensions(entries: List<Triple<Media, Int, Int>>) {
        val byId = entries.associateBy { it.first.id }
        state.update { current ->
            current.copy(
                items =
                    current.items.map { m ->
                        val e = byId[m.id]
                        if (e != null && e.first.revision == m.revision && m.width <= 0)
                            m.copy(width = e.second, height = e.third, dimensionsVerified = false)
                        else m
                    }
            )
        }
        withContext(Dispatchers.IO) {
            entries.forEach { (media, w, h) ->
                if (media.source !in state.value.scanning)
                    db.dimensions(media.id, w, h, false, media.revision)
            }
        }
    }

    suspend fun updateDimensions(m: Media, w: Int, h: Int, verified: Boolean = false) {
        if (w <= 0 || h <= 0 || (m.width == w && m.height == h && m.dimensionsVerified == verified))
            return
        state.update { s ->
            s.copy(
                items =
                    s.items.map {
                        if (it.id == m.id)
                            it.copy(width = w, height = h, dimensionsVerified = verified)
                        else it
                    }
            )
        }
        // Persist only once, after the full source index commits; a background thumbnail must not
        // replace a running scan.
        if (m.source !in state.value.scanning)
            withContext(Dispatchers.IO) { db.dimensions(m.id, w, h, verified, m.revision) }
    }
}

object DocumentsContractCompat {
    fun root(uri: Uri): Uri =
        android.provider.DocumentsContract.buildDocumentUriUsingTree(
            uri,
            android.provider.DocumentsContract.getTreeDocumentId(uri),
        )
}

fun bytesText(bytes: Long): String =
    when {
        bytes >= 1024L * 1024 * 1024 -> "%.1f GB".format(bytes.toDouble() / 1024 / 1024 / 1024)
        bytes >= 1024 * 1024 -> "%.1f MB".format(bytes.toDouble() / 1024 / 1024)
        else -> "${bytes/1024} KB"
    }
