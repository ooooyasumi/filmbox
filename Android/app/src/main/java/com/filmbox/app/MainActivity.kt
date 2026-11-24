package com.filmbox.app

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.exifinterface.media.ExifInterface
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val graph
        get() = (application as FilmboxApplication).graph

    private var consentAction: (() -> Unit)? = null
    private val consent =
        registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
            val next = consentAction
            consentAction = null
            if (result.resultCode == Activity.RESULT_OK) next?.invoke()
        }
    lateinit var actions: MediaActions

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        actions =
            MediaActions(this, graph) { request, after ->
                consentAction = after
                consent.launch(IntentSenderRequest.Builder(request).build())
            }
        setContent { FilmboxRoot(graph, actions) }
    }

    override fun onResume() {
        super.onResume()
        graph.onResume()
    }
}

class MediaActions(
    private val activity: MainActivity,
    private val graph: AppGraph,
    private val consent: (android.content.IntentSender, () -> Unit) -> Unit,
) {
    var onMessage: (String) -> Unit = {}

    private fun task(block: suspend () -> Unit) {
        graph.scope.launch {
            try {
                block()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                onMessage("无法完成操作")
            }
        }
    }

    private suspend fun shareUri(m: Media): Uri =
        if (m.cloud)
            FileProvider.getUriForFile(activity, "${activity.packageName}.files", graph.download(m))
        else Uri.parse(m.uri)

    fun share(items: List<Media>) = task {
        val uris = ArrayList(items.map { shareUri(it) })
        if (uris.isEmpty()) return@task
        val intent =
            Intent(if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
                type =
                    if (items.all { !it.video }) "image/*"
                    else if (items.all { it.video }) "video/*" else "*/*"
                if (uris.size == 1) putExtra(Intent.EXTRA_STREAM, uris.first())
                else putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                clipData =
                    ClipData.newUri(activity.contentResolver, "媒体", uris.first()).also { c ->
                        uris.drop(1).forEach { c.addItem(ClipData.Item(it)) }
                    }
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        activity.startActivity(Intent.createChooser(intent, "分享"))
    }

    fun openExternal(m: Media) = task {
        val uri = shareUri(m)
        activity.startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, m.mime)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                "打开方式",
            )
        )
    }

    fun copy(items: List<Media>) = task {
        val uris = items.map { shareUri(it) }
        if (uris.isNotEmpty()) {
            val clip =
                ClipData.newUri(activity.contentResolver, "菲林盒", uris.first()).also { c ->
                    uris.drop(1).forEach { c.addItem(ClipData.Item(it)) }
                }
            (activity.getSystemService(ClipboardManager::class.java)).setPrimaryClip(clip)
            onMessage("已复制")
        }
    }

    fun trash(items: List<Media>) {
        val local = items.filter { !it.cloud }
        if (local.isEmpty()) return
        val store = local.filter { Uri.parse(it.uri).authority == MediaStore.AUTHORITY }
        val other = local - store.toSet()
        if (other.isNotEmpty()) {
            onMessage("此文件夹请在系统文件管理器中删除")
            return
        }
        runCatching {
                val request =
                    MediaStore.createTrashRequest(
                        activity.contentResolver,
                        store.map { Uri.parse(it.uri) },
                        true,
                    )
                consent(request.intentSender) {
                    store.map { it.source }.distinct().forEach { graph.refresh(it) }
                }
            }
            .onFailure { onMessage("无法完成操作") }
    }

    private fun write(m: Media, operation: suspend () -> Unit) {
        if (m.cloud) return
        val uri = Uri.parse(m.uri)
        if (uri.authority == MediaStore.AUTHORITY) {
            runCatching {
                    val request =
                        MediaStore.createWriteRequest(activity.contentResolver, listOf(uri))
                    consent(request.intentSender) {
                        task {
                            operation()
                            graph.refresh(m.source)
                        }
                    }
                }
                .onFailure { onMessage("无法完成操作") }
        } else
            task {
                operation()
                graph.refresh(m.source)
            }
    }

    fun rename(m: Media, name: String) {
        val cleaned = name.trim()
        if (cleaned.isBlank() || cleaned.contains('/') || cleaned.contains('\\')) return
        val suffix = m.name.substringAfterLast('.', "")
        val final =
            if (suffix.isNotEmpty() && !cleaned.endsWith(".$suffix", true)) "$cleaned.$suffix"
            else cleaned
        write(m) {
            withContext(Dispatchers.IO) {
                val u = Uri.parse(m.uri)
                if (DocumentsContract.isDocumentUri(activity, u))
                    DocumentsContract.renameDocument(activity.contentResolver, u, final)
                else
                    activity.contentResolver.update(
                        u,
                        ContentValues().apply { put(MediaStore.MediaColumns.DISPLAY_NAME, final) },
                        null,
                        null,
                    )
            }
        }
    }

    fun canRotate(m: Media) =
        !m.cloud && !m.video && m.mime in setOf("image/jpeg", "image/png", "image/webp")

    fun rotate(m: Media, right: Boolean) {
        if (!canRotate(m)) return
        write(m) {
            withContext(Dispatchers.IO) {
                activity.contentResolver.openFileDescriptor(Uri.parse(m.uri), "rw")?.use { fd ->
                    val exif = ExifInterface(fd.fileDescriptor)
                    if (right) exif.rotate(90) else exif.rotate(-90)
                    exif.saveAttributes()
                    if (Uri.parse(m.uri).authority == MediaStore.AUTHORITY)
                        activity.contentResolver.update(
                            Uri.parse(m.uri),
                            ContentValues().apply {
                                put(MediaStore.Images.Media.ORIENTATION, exif.rotationDegrees)
                                put(
                                    MediaStore.MediaColumns.DATE_MODIFIED,
                                    System.currentTimeMillis() / 1000,
                                )
                            },
                            null,
                            null,
                        )
                } ?: error("无法保存")
                // Ask the provider to invalidate metadata and thumbnails for the changed original.
                activity.contentResolver.notifyChange(Uri.parse(m.uri), null)
            }
        }
    }
}
