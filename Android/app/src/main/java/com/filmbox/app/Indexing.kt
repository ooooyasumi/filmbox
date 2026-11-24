package com.filmbox.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationCompat
import androidx.work.*
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject

/** Counts are exact; a cloud's total is unknown until the directory walk completes. */
data class IndexProgress(
    val found: Int = 0,
    val folders: Int = 0,
    val pending: Int = 1,
    val running: Boolean = false,
) {
    fun data() = workDataOf("found" to found, "folders" to folders, "pending" to pending)
}

/**
 * A folder checkpoint and its discovered entries are committed in one transaction. No originals.
 */
class CloudIndexStore(context: Context, name: String = "cloud-index.db") :
    SQLiteOpenHelper(context, name, null, 1) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE runs(source TEXT PRIMARY KEY, signature TEXT NOT NULL, created INTEGER NOT NULL)"
        )
        db.execSQL(
            "CREATE TABLE folders(source TEXT, id TEXT, name TEXT, path TEXT, done INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source,id))"
        )
        db.execSQL("CREATE TABLE entries(source TEXT, id TEXT, data TEXT, PRIMARY KEY(source,id))")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    @Synchronized
    fun begin(library: Library, ignoreHidden: Boolean) {
        val signature = "${library.account}:${library.folderId}:${library.path}:$ignoreHidden"
        val db = writableDatabase
        val existing =
            db.rawQuery("SELECT signature,created FROM runs WHERE source=?", arrayOf(library.id))
                .use { if (it.moveToFirst()) it.getString(0) to it.getLong(1) else null }
        if (
            existing?.first == signature &&
                System.currentTimeMillis() - existing.second < 7 * 86400000L
        )
            return
        db.beginTransaction()
        try {
            clearRows(db, library.id)
            db.execSQL(
                "INSERT INTO runs VALUES(?,?,?)",
                arrayOf<Any>(library.id, signature, System.currentTimeMillis()),
            )
            db.execSQL(
                "INSERT INTO folders(source,id,name,path) VALUES(?,?,?,?)",
                arrayOf(library.id, library.folderId, library.name, library.path),
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    @Synchronized
    fun next(source: String): CloudFolder? =
        readableDatabase
            .rawQuery(
                "SELECT id,name,path FROM folders WHERE source=? AND done=0 ORDER BY rowid LIMIT 1",
                arrayOf(source),
            )
            .use {
                if (it.moveToFirst()) CloudFolder(it.getString(0), it.getString(1), it.getString(2))
                else null
            }

    @Synchronized
    fun save(source: String, folder: CloudFolder, media: List<Media>, children: List<CloudFolder>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            children.forEach { f ->
                db.insertWithOnConflict(
                    "folders",
                    null,
                    ContentValues().apply {
                        put("source", source)
                        put("id", f.id)
                        put("name", f.name)
                        put("path", f.path)
                        put("done", 0)
                    },
                    SQLiteDatabase.CONFLICT_IGNORE,
                )
            }
            media.forEach { m ->
                db.insertWithOnConflict(
                    "entries",
                    null,
                    ContentValues().apply {
                        put("source", source)
                        put("id", m.id)
                        put("data", m.json().toString())
                    },
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            db.execSQL(
                "UPDATE folders SET done=1 WHERE source=? AND id=?",
                arrayOf(source, folder.id),
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    @Synchronized
    fun progress(source: String): IndexProgress {
        val db = readableDatabase
        val found =
            db.rawQuery("SELECT COUNT(*) FROM entries WHERE source=?", arrayOf(source)).use {
                it.moveToFirst()
                it.getInt(0)
            }
        return db.rawQuery(
                "SELECT COUNT(*),COALESCE(SUM(done),0) FROM folders WHERE source=?",
                arrayOf(source),
            )
            .use {
                it.moveToFirst()
                IndexProgress(found, it.getInt(1), (it.getInt(0) - it.getInt(1)).coerceAtLeast(0))
            }
    }

    @Synchronized
    fun entries(source: String): List<Media> = buildList {
        readableDatabase
            .rawQuery("SELECT data FROM entries WHERE source=? ORDER BY rowid", arrayOf(source))
            .use { while (it.moveToNext()) add(Media.read(JSONObject(it.getString(0)))) }
    }

    private fun clearRows(db: SQLiteDatabase, source: String) {
        for (table in listOf("entries", "folders", "runs")) db.delete(
            table,
            "source=?",
            arrayOf(source),
        )
    }

    @Synchronized
    fun clear(source: String) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            clearRows(db, source)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }
}

class CloudIndexWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {
    companion object {
        const val TAG = "filmbox.cloud.index"

        fun name(source: String) = "cloud-index:$source"

        fun enqueue(context: Context, source: String) {
            val work =
                OneTimeWorkRequestBuilder<CloudIndexWorker>()
                    .setInputData(workDataOf("source" to source))
                    .addTag(TAG)
                    .addTag("source:$source")
                    .addTag("created:${System.currentTimeMillis()}")
                    .setConstraints(
                        Constraints.Builder()
                            .setRequiredNetworkRequest(
                                android.net.NetworkRequest.Builder()
                                    .addCapability(
                                        android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET
                                    )
                                    .build(),
                                NetworkType.CONNECTED,
                            )
                            .build()
                    )
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork(name(source), ExistingWorkPolicy.KEEP, work)
        }
    }

    private val source
        get() = inputData.getString("source").orEmpty()

    private fun notification(progress: IndexProgress): android.app.Notification {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(TAG, "资源库索引", NotificationManager.IMPORTANCE_LOW)
        )
        val intent =
            Intent(applicationContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return NotificationCompat.Builder(applicationContext, TAG)
            .setSmallIcon(com.filmbox.app.R.drawable.filmbox_foreground)
            .setContentTitle("正在整理云端照片")
            .setContentText("已找到 ${progress.found} 项 · 已检查 ${progress.folders} 个文件夹")
            .setProgress(0, 0, true)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setContentIntent(
                PendingIntent.getActivity(
                    applicationContext,
                    0,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            )
            .build()
    }

    private fun foregroundInfo(progress: IndexProgress) =
        ForegroundInfo(
            source.hashCode(),
            notification(progress),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )

    override suspend fun getForegroundInfo(): ForegroundInfo =
        withContext(Dispatchers.IO) {
            foregroundInfo(
                (applicationContext as FilmboxApplication).graph.cloudIndex.progress(source)
            )
        }

    override suspend fun doWork(): Result {
        val graph = (applicationContext as FilmboxApplication).graph
        val library =
            graph.ui.value.libraries.firstOrNull { it.id == source && it.cloud }
                ?: return Result.success()
        return graph.cloudScanSlots.withPermit {
            withContext(Dispatchers.IO) {
                try {
                    graph.cloudIndex.begin(library, graph.ui.value.ignoreHidden)
                    val started = android.os.SystemClock.elapsedRealtime()
                    var progress = graph.cloudIndex.progress(source)
                    setProgress(progress.data())
                    if (android.os.Build.VERSION.SDK_INT < 31)
                        setForeground(foregroundInfo(progress))
                    while (true) {
                        ensureActive()
                        val folder = graph.cloudIndex.next(source) ?: break
                        val (media, children) =
                            graph.cloud.scanFolder(library, folder, graph.ui.value.ignoreHidden)
                        ensureActive()
                        graph.cloudIndex.save(source, folder, media, children)
                        progress = graph.cloudIndex.progress(source)
                        setProgress(progress.data())
                        if (android.os.Build.VERSION.SDK_INT < 31)
                            setForeground(foregroundInfo(progress))
                        // Yield before the OS execution limit; the next attempt resumes at a
                        // directory boundary.
                        if (
                            android.os.SystemClock.elapsedRealtime() - started > 8 * 60 * 1000L &&
                                progress.pending > 0
                        )
                            return@withContext Result.retry()
                    }
                    ensureActive()
                    if (graph.ui.value.libraries.none { it.id == source })
                        return@withContext Result.success()
                    graph.db.replace(source, graph.cloudIndex.entries(source))
                    graph.cloudIndex.clear(source)
                    graph.reload()
                    Result.success()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (BuildConfig.DEBUG)
                        android.util.Log.w("FilmboxIndex", e.javaClass.simpleName)
                    val issue = RecoveryProblem.from(e, true)
                    setProgress(
                        Data.Builder()
                            .putAll(graph.cloudIndex.progress(source).data())
                            .putString("errorCode", issue.code)
                            .build()
                    )
                    if (issue.automaticRetry && runAttemptCount < 2) Result.retry()
                    else
                        Result.failure(
                            workDataOf("errorCode" to issue.code, "error" to issue.title)
                        )
                }
            }
        }
    }
}

@Composable
fun IndexActivityCard(s: GalleryState) {
    if (s.indexing.isEmpty()) return
    val c = LocalFilm.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val networkAvailable =
        context.getSystemService(android.net.ConnectivityManager::class.java).activeNetwork != null
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        s.indexing
            .filterKeys { it !in s.issues }
            .forEach { (id, p) ->
                val name = s.libraries.firstOrNull { it.id == id }?.name ?: "云端资源库"
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(
                        "$name · ${if(p.running)"正在索引" else if(!networkAvailable) "等待网络连接" else "等待开始"}",
                        Modifier.weight(1f),
                        fontSize = 12.sp,
                        color = c.text,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text("已找到 ${p.found} 项", fontSize = 11.sp, color = c.secondary)
                }
                Spacer(Modifier.height(6.dp))
                FilmProgress()
                Spacer(Modifier.height(4.dp))
                Text("已检查 ${p.folders} 个文件夹", fontSize = 10.sp, color = c.secondary)
            }
    }
}
