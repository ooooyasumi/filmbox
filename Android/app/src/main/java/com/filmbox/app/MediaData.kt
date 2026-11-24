package com.filmbox.app

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject

/** URIs, never raw storage paths, are the authority for local media access. */
data class Media(
    val id: String,
    val source: String,
    val uri: String,
    val name: String,
    val mime: String,
    val width: Int = 0,
    val height: Int = 0,
    val date: Long = 0,
    val modified: Long = 0,
    val size: Long = 0,
    val duration: Long = 0,
    val folder: String = "",
    val remoteId: String = "",
    val remotePath: String = "",
    val favorite: Boolean = false,
    val hidden: Boolean = false,
    val albums: Set<String> = emptySet(),
    val orientation: Int = 0,
    val identity: String = "",
    val dimensionsVerified: Boolean = width > 0 && height > 0,
) {
    val video
        get() = mime.startsWith("video/")

    val cloud
        get() = remoteId.isNotEmpty()

    val ratio
        get() = if (width > 0 && height > 0) (width.toFloat() / height).coerceIn(.12f, 8f) else 1f

    val format
        get() = name.substringAfterLast('.', mime.substringAfter('/')).uppercase(Locale.ROOT)

    val identityKey
        get() = identity.ifBlank { if (cloud) id else uri }

    val revision
        get() = "$identityKey:$modified:$size:$orientation"

    fun json() =
        JSONObject()
            .put("id", id)
            .put("source", source)
            .put("uri", uri)
            .put("name", name)
            .put("mime", mime)
            .put("width", width)
            .put("height", height)
            .put("date", date)
            .put("modified", modified)
            .put("size", size)
            .put("duration", duration)
            .put("folder", folder)
            .put("remoteId", remoteId)
            .put("remotePath", remotePath)
            .put("orientation", orientation)
            .put("identity", identity)
            .put("dimensionsVerified", dimensionsVerified)

    companion object {
        fun read(j: JSONObject) =
            Media(
                j.getString("id"),
                j.getString("source"),
                j.optString("uri"),
                j.getString("name"),
                j.optString("mime"),
                j.optInt("width"),
                j.optInt("height"),
                j.optLong("date"),
                j.optLong("modified"),
                j.optLong("size"),
                j.optLong("duration"),
                j.optString("folder"),
                j.optString("remoteId"),
                j.optString("remotePath"),
                orientation = j.optInt("orientation"),
                identity = j.optString("identity"),
                dimensionsVerified =
                    j.optBoolean(
                        "dimensionsVerified",
                        j.optInt("width") > 0 && j.optInt("height") > 0,
                    ),
            )
    }
}

data class Library(
    val id: String,
    val name: String,
    val uri: String = "",
    val account: String = "",
    val folderId: String = "",
    val path: String = "/",
) {
    val cloud
        get() = account.isNotEmpty()

    fun json() =
        JSONObject()
            .put("id", id)
            .put("name", name)
            .put("uri", uri)
            .put("account", account)
            .put("folderId", folderId)
            .put("path", path)

    companion object {
        fun read(j: JSONObject) =
            Library(
                j.getString("id"),
                j.getString("name"),
                j.optString("uri"),
                j.optString("account"),
                j.optString("folderId"),
                j.optString("path", "/"),
            )
    }
}

data class Album(val id: String, val name: String)

enum class Scope {
    ALL,
    FAVORITES,
    HIDDEN,
    ALBUM,
    LIBRARY,
}

enum class BrowseMode {
    GRID,
    REEL,
}

enum class SortKey {
    DATE,
    NAME,
    SIZE,
}

data class Filter(
    val type: Int = 0,
    val source: Int = 0,
    val download: Int = 0,
    val formats: Set<String> = emptySet(),
) {
    val count
        get() = listOf(type != 0, source != 0, download != 0, formats.isNotEmpty()).count { it }

    fun matches(m: Media, downloaded: Boolean) =
        (type == 0 || (type == 2) == m.video) &&
            (source == 0 || (source == 2) == m.cloud) &&
            (download == 0 || (m.cloud && ((download == 1) == downloaded))) &&
            (formats.isEmpty() || m.format in formats)
}

data class PhotoRow(val items: List<Media>, val height: Float, val widths: List<Float>)

fun justifiedRows(
    items: List<Media>,
    width: Float,
    target: Float,
    gap: Float = 3f,
): List<PhotoRow> {
    if (width <= 0f || items.isEmpty()) return emptyList()
    val rows = mutableListOf<PhotoRow>()
    var pending = mutableListOf<Media>()
    var ratio = 0f
    fun flush(last: Boolean) {
        if (pending.isEmpty()) return
        val fit = (width - gap * (pending.size - 1)) / ratio
        val h = if (last) min(target, fit) else fit
        rows += PhotoRow(pending.toList(), h, pending.map { h * it.ratio })
        pending = mutableListOf()
        ratio = 0f
    }
    items.forEach { m ->
        pending.add(m)
        ratio += m.ratio
        if (ratio * target + gap * (pending.size - 1) >= width) flush(false)
    }
    flush(true)
    return rows
}

fun dayKey(timestamp: Long): String =
    Instant.ofEpochMilli(max(timestamp, 0)).atZone(ZoneId.systemDefault()).toLocalDate().toString()

fun dateText(timestamp: Long, pattern: String = "yyyy年M月d日") =
    DateTimeFormatter.ofPattern(pattern, Locale.CHINA)
        .format(Instant.ofEpochMilli(max(timestamp, 0)).atZone(ZoneId.systemDefault()))

fun groupKey(timestamp: Long, level: Int): String {
    val d = Instant.ofEpochMilli(max(timestamp, 0)).atZone(ZoneId.systemDefault()).toLocalDate()
    return when (level) {
        2 -> "${d.year}年${d.monthValue}月"
        1 -> d.minusDays((d.dayOfWeek.value - 1).toLong()).toString()
        else -> d.toString()
    }
}

fun reelWidth(ratio: Float, viewportWidth: Float, viewportHeight: Float) =
    min(viewportWidth, viewportHeight * ratio)

fun focusedIndex(centers: List<Pair<Int, Float>>, center: Float): Int? =
    centers.minByOrNull { abs(it.second - center) }?.first

/** Metadata and user organization are stored independently: reindexing cannot erase albums. */
class MediaDatabase(context: Context, databaseName: String = "filmbox.db") :
    SQLiteOpenHelper(context, databaseName, null, 1) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE media(id TEXT PRIMARY KEY, source TEXT NOT NULL, data TEXT NOT NULL)"
        )
        db.execSQL("CREATE INDEX media_source ON media(source)")
        db.execSQL(
            "CREATE TABLE marks(id TEXT PRIMARY KEY, favorite INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0)"
        )
        db.execSQL("CREATE TABLE albums(id TEXT PRIMARY KEY, name TEXT NOT NULL)")
        db.execSQL("CREATE TABLE members(album TEXT, media TEXT, PRIMARY KEY(album,media))")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    @Synchronized
    fun read(allowedSources: Set<String>? = null): List<Media> {
        val marks = mutableMapOf<String, Pair<Boolean, Boolean>>()
        val members = mutableMapOf<String, MutableSet<String>>()
        readableDatabase.rawQuery("SELECT * FROM marks", null).use { c ->
            while (c.moveToNext()) marks[c.getString(0)] = (c.getInt(1) != 0) to (c.getInt(2) != 0)
        }
        readableDatabase.rawQuery("SELECT media,album FROM members", null).use { c ->
            while (c.moveToNext()) members
                .getOrPut(c.getString(0)) { mutableSetOf() }
                .add(c.getString(1))
        }
        return buildList {
            readableDatabase.rawQuery("SELECT data FROM media", null).use { c ->
                while (c.moveToNext()) {
                    val m = Media.read(JSONObject(c.getString(0)))
                    if (allowedSources == null || m.source in allowedSources)
                        add(
                            m.copy(
                                favorite = marks[m.identityKey]?.first ?: false,
                                hidden = marks[m.identityKey]?.second ?: false,
                                albums = members[m.identityKey] ?: emptySet(),
                            )
                        )
                }
            }
        }
    }

    @Synchronized
    fun replace(source: String, items: List<Media>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            // Compare the snapshot, update only changed records, remove missing files only after a
            // complete scan.
            val old = mutableMapOf<String, String>()
            db.rawQuery("SELECT id,data FROM media WHERE source=?", arrayOf(source)).use { c ->
                while (c.moveToNext()) old[c.getString(0)] = c.getString(1)
            }
            items.forEach { m ->
                val previous = old.remove(m.id)
                val known =
                    if (m.width <= 0 || m.height <= 0) previous?.let { Media.read(JSONObject(it)) }
                    else null
                val entry =
                    if (
                        known != null &&
                            known.revision == m.revision &&
                            (m.width <= 0 || m.height <= 0)
                    )
                        m.copy(
                            width = known.width,
                            height = known.height,
                            dimensionsVerified = known.dimensionsVerified,
                        )
                    else m
                val json = entry.json().toString()
                if (previous != json)
                    db.insertWithOnConflict(
                        "media",
                        null,
                        ContentValues().apply {
                            put("id", m.id)
                            put("source", source)
                            put("data", json)
                        },
                        SQLiteDatabase.CONFLICT_REPLACE,
                    )
            }
            old.keys.forEach { db.delete("media", "id=?", arrayOf(it)) }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    @Synchronized
    fun mark(ids: Set<String>, favorite: Boolean? = null, hidden: Boolean? = null) {
        writableDatabase.beginTransaction()
        try {
            ids.forEach { id ->
                writableDatabase.execSQL("INSERT OR IGNORE INTO marks(id) VALUES(?)", arrayOf(id))
                favorite?.let {
                    writableDatabase.execSQL(
                        "UPDATE marks SET favorite=? WHERE id=?",
                        arrayOf<Any>(if (it) 1 else 0, id),
                    )
                }
                hidden?.let {
                    writableDatabase.execSQL(
                        "UPDATE marks SET hidden=? WHERE id=?",
                        arrayOf<Any>(if (it) 1 else 0, id),
                    )
                }
            }
            writableDatabase.setTransactionSuccessful()
        } finally {
            writableDatabase.endTransaction()
        }
    }

    @Synchronized
    fun albums(): List<Album> = buildList {
        readableDatabase.rawQuery("SELECT id,name FROM albums ORDER BY rowid", null).use { c ->
            while (c.moveToNext()) add(Album(c.getString(0), c.getString(1)))
        }
    }

    @Synchronized
    fun addAlbum(name: String): String {
        val id = java.util.UUID.randomUUID().toString()
        writableDatabase.execSQL("INSERT INTO albums VALUES(?,?)", arrayOf(id, name))
        return id
    }

    @Synchronized
    fun renameAlbum(id: String, name: String) {
        writableDatabase.execSQL("UPDATE albums SET name=? WHERE id=?", arrayOf(name, id))
    }

    @Synchronized
    fun deleteAlbum(id: String) {
        writableDatabase.beginTransaction()
        try {
            writableDatabase.delete("members", "album=?", arrayOf(id))
            writableDatabase.delete("albums", "id=?", arrayOf(id))
            writableDatabase.setTransactionSuccessful()
        } finally {
            writableDatabase.endTransaction()
        }
    }

    @Synchronized
    fun membership(album: String, ids: Set<String>, add: Boolean) {
        writableDatabase.beginTransaction()
        try {
            ids.forEach {
                if (add)
                    writableDatabase.execSQL(
                        "INSERT OR IGNORE INTO members VALUES(?,?)",
                        arrayOf(album, it),
                    )
                else writableDatabase.delete("members", "album=? AND media=?", arrayOf(album, it))
            }
            writableDatabase.setTransactionSuccessful()
        } finally {
            writableDatabase.endTransaction()
        }
    }

    @Synchronized
    fun dimensions(
        id: String,
        w: Int,
        h: Int,
        verified: Boolean = true,
        expectedRevision: String? = null,
    ) {
        val item =
            readableDatabase.rawQuery("SELECT data FROM media WHERE id=?", arrayOf(id)).use {
                if (it.moveToFirst()) Media.read(JSONObject(it.getString(0))) else null
            } ?: return
        if (expectedRevision != null && item.revision != expectedRevision) return
        writableDatabase.execSQL(
            "UPDATE media SET data=? WHERE id=?",
            arrayOf(
                item.copy(width = w, height = h, dimensionsVerified = verified).json().toString(),
                id,
            ),
        )
    }

    @Synchronized
    fun removeSource(id: String) {
        writableDatabase.delete("media", "source=?", arrayOf(id))
    }
}

class LocalIndexer(private val context: Context) {
    suspend fun gallery(ignoreHidden: Boolean): List<Media> {
        val result = mutableListOf<Media>()
        for (video in listOf(false, true)) {
            currentCoroutineContext().ensureActive()
            val uri =
                if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            val cols =
                mutableListOf(
                    "_id",
                    "_display_name",
                    "mime_type",
                    "width",
                    "height",
                    "datetaken",
                    "date_modified",
                    "date_added",
                    "_size",
                    "bucket_display_name",
                    "relative_path",
                )
            cols.add(if (video) "duration" else "orientation")
            // Each collection can be granted independently on Android 13+.
            try {
                context.contentResolver
                    .query(uri, cols.toTypedArray(), "is_trashed=0 AND is_pending=0", null, null)
                    ?.use { c ->
                        while (c.moveToNext()) {
                            currentCoroutineContext().ensureActive()
                            val name = c.getString(1) ?: continue
                            val path = c.getString(10) ?: ""
                            if (
                                ignoreHidden &&
                                    (name.startsWith('.') ||
                                        path.split('/').any { it.startsWith('.') })
                            )
                                continue
                            val u = ContentUris.withAppendedId(uri, c.getLong(0)).toString()
                            val rotated = !video && c.getInt(11) % 180 != 0
                            val w = c.getInt(if (rotated) 4 else 3)
                            val h = c.getInt(if (rotated) 3 else 4)
                            val taken = c.getLong(5).takeIf { it > 0 } ?: (c.getLong(7) * 1000)
                            result +=
                                Media(
                                    u,
                                    "gallery",
                                    u,
                                    name,
                                    c.getString(2) ?: if (video) "video/mp4" else "image/jpeg",
                                    w,
                                    h,
                                    taken,
                                    c.getLong(6) * 1000,
                                    c.getLong(8),
                                    if (video) c.getLong(11) else 0,
                                    c.getString(9) ?: "相机",
                                    orientation = if (video) 0 else c.getInt(11),
                                    identity = localIdentity(context, Uri.parse(u)),
                                )
                        }
                    }
            } catch (_: SecurityException) {
                /* A partially granted collection is not a scan failure. */
            }
        }
        return result
    }

    suspend fun folder(library: Library, ignoreHidden: Boolean): List<Media> {
        val tree = Uri.parse(library.uri)
        val root = DocumentsContract.getTreeDocumentId(tree)
        val found = mutableListOf<Media>()
        val visited = mutableSetOf<String>()
        val queue = ArrayDeque<String>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val dir = queue.removeFirst()
            if (!visited.add(dir)) continue
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, dir)
            val cols =
                arrayOf("document_id", "_display_name", "mime_type", "_size", "last_modified")
            val cursor =
                context.contentResolver.query(children, cols, null, null, null) ?: error("文件夹不可用")
            cursor.use { c ->
                while (c.moveToNext()) {
                    currentCoroutineContext().ensureActive()
                    val doc = c.getString(0)
                    val name = c.getString(1) ?: continue
                    val mime = c.getString(2) ?: ""
                    if (ignoreHidden && name.startsWith('.')) continue
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        queue.add(doc)
                        continue
                    }
                    if (!mime.startsWith("image/") && !mime.startsWith("video/")) continue
                    val u = DocumentsContract.buildDocumentUriUsingTree(tree, doc)
                    val modified = c.getLong(4)
                    found +=
                        Media(
                            "${library.id}:$doc",
                            library.id,
                            u.toString(),
                            name,
                            mime,
                            date = modified,
                            modified = modified,
                            size = c.getLong(3),
                            folder = library.name,
                            identity = localIdentity(context, u),
                        )
                }
            }
        }
        return found
    }
}

fun timelineExtent(count: Int, vertical: Boolean): Float =
    (if (vertical) 52f else 76f) +
        (kotlin.math.ln(1.0 + count.coerceAtLeast(0)) * (if (vertical) 3 else 5))
            .toFloat()
            .coerceAtMost(if (vertical) 18f else 28f)

fun localIdentity(context: Context, uri: Uri): String {
    val media =
        if (uri.authority == MediaStore.AUTHORITY) uri
        else runCatching { MediaStore.getMediaUri(context, uri) }.getOrNull()
    return if (media != null)
        runCatching { "media:${ContentUris.parseId(media)}" }.getOrDefault(uri.toString())
    else uri.toString()
}
