package com.filmbox.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.security.SecureRandom
import java.time.Instant
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

data class CloudAccount(val id: String, val provider: String, val name: String)

data class CloudFolder(val id: String, val name: String, val path: String)

class CloudFailure(val reason: String) :
    IOException(
        when (reason) {
            "thumbnail_unavailable" -> "暂无预览"
            "invalid_request" -> "请检查云盘地址和登录信息，再连接。"
            else -> RecoveryProblem.code(reason).let { it.title + "。" + it.detail }
        }
    )

/**
 * Account secrets are encrypted with an Android Keystore key; neither backup nor logs carry them.
 */
class CredentialVault(private val context: Context) {
    private val lock = Any()
    private val prefs = context.getSharedPreferences("cloud-vault", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey("filmbox.cloud.v1", null) as? SecretKey)?.let {
            return it
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                            "filmbox.cloud.v1",
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build()
                )
            }
            .generateKey()
    }

    fun read(id: String): JSONObject? =
        synchronized(lock) {
            val encoded = prefs.getString(id, null) ?: return@synchronized null
            runCatching {
                    val bytes = Base64.decode(encoded, Base64.NO_WRAP)
                    val cipher =
                        Cipher.getInstance("AES/GCM/NoPadding").apply {
                            init(
                                Cipher.DECRYPT_MODE,
                                key(),
                                GCMParameterSpec(128, bytes.copyOfRange(0, 12)),
                            )
                        }
                    JSONObject(
                        String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
                    )
                }
                .getOrNull()
        }

    fun write(id: String, value: JSONObject) =
        synchronized(lock) {
            val cipher =
                Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
            prefs
                .edit()
                .putString(
                    id,
                    Base64.encodeToString(
                        cipher.iv + cipher.doFinal(value.toString().toByteArray()),
                        Base64.NO_WRAP,
                    ),
                )
                .commit()
            Unit
        }

    fun updateCredential(id: String, credential: String, revision: Long) =
        synchronized(lock) {
            read(id)?.let { saved ->
                if (revision >= saved.optLong("revision")) {
                    saved.put("credential", credential).put("revision", revision)
                    write(id, saved)
                }
            }
        }

    fun remove(id: String) {
        synchronized(lock) { prefs.edit().remove(id).commit() }
    }

    fun accounts(): List<CloudAccount> =
        prefs.all.keys.mapNotNull { id ->
            read(id)?.let { CloudAccount(id, it.optString("provider"), it.optString("name")) }
        }
}

class CloudEngine(private val context: Context) {
    val vault = CredentialVault(context)
    private val startMutex = Mutex()
    private val connectMutex = Mutex()
    private var process: Process? = null
    private val connected = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val secret =
        ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    @Volatile private var base = ""
    val http: OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .addInterceptor { chain ->
                val req = chain.request()
                // Never attach the local engine token to upstream cloud hosts or redirects.
                val local = base.isNotEmpty() && req.url.toString().startsWith("$base/")
                chain.proceed(
                    if (local) req.newBuilder().header("Authorization", "Bearer $secret").build()
                    else req
                )
            }
            .build()

    suspend fun start() =
        startMutex.withLock {
            if (process?.isAlive == true && base.isNotEmpty()) return@withLock
            withContext(Dispatchers.IO) {
                connected.clear()
                val executable =
                    File(context.applicationInfo.nativeLibraryDir, "libfilmbox_cloud.so")
                if (!executable.isFile) throw CloudFailure("engine_unavailable")
                val p =
                    ProcessBuilder(executable.absolutePath)
                        .apply {
                            environment()["FILMBOX_CLOUD_SECRET"] = secret
                            environment()["SSL_CERT_DIR"] =
                                "/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts"
                        }
                        .start()
                process = p
                val line =
                    p.inputStream.bufferedReader().readLine()
                        ?: throw CloudFailure("engine_unavailable")
                val port = JSONObject(line).getInt("port")
                check(port in 1..65535)
                base = "http://127.0.0.1:$port"
            }
        }

    var onProblem: (String, RecoveryProblem?) -> Unit = { _, _ -> }
    private val blocked =
        java.util.concurrent.ConcurrentHashMap<String, Pair<RecoveryProblem, Long>>()

    fun allowRecovery(account: String) {
        blocked.remove(account)
    }

    fun problem(account: String): RecoveryProblem? = blocked[account]?.first

    fun report(account: String, problem: RecoveryProblem) {
        if (problem.accountWide && account.isNotEmpty()) {
            val delay =
                if (problem == RecoveryProblem.LOGIN) Long.MAX_VALUE
                else
                    System.currentTimeMillis() +
                        if (problem == RecoveryProblem.LIMITED) 60000 else 15000
            blocked[account] = problem to delay
            onProblem(account, problem)
        }
    }

    fun responseFailure(response: Response, account: String): CloudFailure {
        // Only our helper emits this header; never infer login expiry from a CDN status.
        val code =
            response.header("X-Filmbox-Error")
                ?: when (response.code) {
                    404,
                    410 -> "not_found"
                    429 -> "rate_limited"
                    403 -> "access_denied"
                    else -> "unknown"
                }
        report(account, RecoveryProblem.code(code))
        return CloudFailure(code)
    }

    suspend fun request(route: String, body: JSONObject): JSONObject {
        val account = body.optString("account_id")
        val read = route in setOf("files/list", "files/resolve")
        if (read)
            blocked[account]?.let {
                if (System.currentTimeMillis() < it.second) throw CloudFailure(it.first.code)
            }
        for (attempt in 0..1) {
            try {
                val result = requestOnce(route, body)
                if (read && blocked[account]?.first != RecoveryProblem.LOGIN) {
                    blocked.remove(account)
                    onProblem(account, null)
                }
                return result
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                val issue =
                    if (e is java.net.ConnectException) RecoveryProblem.ENGINE
                    else RecoveryProblem.from(e, true)
                if (
                    read &&
                        attempt == 0 &&
                        (issue.automaticRetry ||
                            e is CloudFailure && e.reason == "account_not_connected")
                ) {
                    if (
                        issue == RecoveryProblem.ENGINE ||
                            e is CloudFailure && e.reason == "account_not_connected"
                    ) {
                        startMutex.withLock {
                            process?.destroy()
                            process = null
                            base = ""
                            connected.clear()
                        }
                        ensureConnected(account)
                    }
                    kotlinx.coroutines.delay(600)
                    continue
                }
                if (read) report(account, issue)
                if (e is CloudFailure) throw e
                throw CloudFailure(issue.code)
            }
        }
        throw CloudFailure("engine_unavailable")
    }

    private suspend fun requestOnce(route: String, body: JSONObject): JSONObject {
        start()
        val req =
            Request.Builder()
                .url("$base/v1/$route")
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()
        val response = http.newCall(req).await()
        response.use { r ->
            val result = JSONObject(r.body?.string() ?: "{}")
            val id = body.optString("account_id")
            if (result.has("credential") && id.isNotEmpty())
                withContext(Dispatchers.IO) {
                    vault.updateCredential(
                        id,
                        result.getString("credential"),
                        result.optLong("credential_revision"),
                    )
                }
            if (!r.isSuccessful) {
                val failure = CloudFailure(result.optString("code", "unknown"))
                if (failure.reason == "authentication_expired") report(id, RecoveryProblem.LOGIN)
                throw failure
            }
            return result
        }
    }

    suspend fun connect(
        provider: String,
        credential: String,
        endpoint: String,
        username: String,
        password: String,
        existingId: String? = null,
    ): CloudAccount {
        val id = existingId ?: java.util.UUID.randomUUID().toString()
        val saved =
            JSONObject()
                .put("account_id", id)
                .put("provider", provider)
                .put("credential", credential.trim())
                .put("endpoint", endpoint.trim())
                .put("username", username)
                .put("password", password)
        val result = request("accounts/connect", saved)
        val account = CloudAccount(id, provider, result.getString("name"))
        saved
            .put("name", account.name)
            .put("credential", result.optString("credential", credential))
            .put("revision", result.optLong("credential_revision"))
        withContext(Dispatchers.IO) { vault.write(id, saved) }
        connected.add(id)
        blocked.remove(id)
        onProblem(id, null)
        return account
    }

    private suspend fun ensureConnected(id: String) =
        connectMutex.withLock {
            blocked[id]?.let {
                if (System.currentTimeMillis() < it.second) throw CloudFailure(it.first.code)
            }
            start()
            if (id !in connected) {
                val value =
                    withContext(Dispatchers.IO) { vault.read(id) }
                        ?: throw CloudFailure("authentication_expired")
                // A restarted helper has a fresh revision sequence.
                value.put("revision", 0)
                withContext(Dispatchers.IO) { vault.write(id, value) }
                request("accounts/connect", value)
                connected.add(id)
            }
        }

    suspend fun list(account: String, folder: String, path: String): JSONArray {
        ensureConnected(account)
        return request(
                "files/list",
                JSONObject().put("account_id", account).put("folder_id", folder).put("path", path),
            )
            .optJSONArray("entries") ?: JSONArray()
    }

    suspend fun resolve(m: Media, purpose: String): String {
        ensureConnected(m.sourceAccount())
        return request(
                "files/resolve",
                JSONObject()
                    .put("account_id", m.sourceAccount())
                    .put("file_id", m.remoteId)
                    .put("path", m.remotePath)
                    .put("purpose", purpose),
            )
            .getString("url")
    }

    // Cloud media source is a stable library ID; account IDs are mapped by AppGraph.
    var accountForSource: (String) -> String = { it }

    private fun Media.sourceAccount() = accountForSource(source)

    suspend fun scanFolder(
        library: Library,
        folder: CloudFolder,
        ignoreHidden: Boolean,
    ): Pair<List<Media>, List<CloudFolder>> {
        val media = mutableListOf<Media>()
        val children = mutableListOf<CloudFolder>()
        val entries = list(library.account, folder.id, folder.path)
        for (i in 0 until entries.length()) {
            currentCoroutineContext().ensureActive()
            val e = entries.getJSONObject(i)
            val name = e.optString("name")
            if (ignoreHidden && name.startsWith('.')) continue
            val path = folder.path.trimEnd('/') + "/" + name
            if (e.optBoolean("is_directory")) {
                children += CloudFolder(e.getString("id"), name, path)
                continue
            }
            val mime = mimeFor(name) ?: continue
            fun time(key: String) =
                runCatching { Instant.parse(e.optString(key)).toEpochMilli() }.getOrDefault(0)
            media +=
                Media(
                    "${library.id}:${e.getString("id")}",
                    library.id,
                    "",
                    name,
                    mime,
                    e.optInt("width"),
                    e.optInt("height"),
                    time("created").takeIf { it > 0 } ?: time("modified"),
                    time("modified"),
                    e.optLong("size"),
                    (e.optDouble("duration", 0.0) * 1000).toLong(),
                    library.name,
                    e.getString("id"),
                    path,
                    identity = "${library.account}:${e.getString("id")}",
                )
        }
        return media to children
    }

    suspend fun scan(
        library: Library,
        ignoreHidden: Boolean,
        progress: (Int) -> Unit,
    ): List<Media> {
        val out = mutableListOf<Media>()
        val queue = ArrayDeque<CloudFolder>()
        val visited = mutableSetOf<String>()
        queue.add(CloudFolder(library.folderId, library.name, library.path))
        while (queue.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val folder = queue.removeFirst()
            if (!visited.add(folder.id)) continue
            val (media, children) = scanFolder(library, folder, ignoreHidden)
            out += media
            queue.addAll(children)
            progress(out.size)
        }
        return out
    }

    suspend fun disconnect(id: String) =
        connectMutex.withLock {
            if (process?.isAlive == true)
                runCatching { request("accounts/disconnect", JSONObject().put("account_id", id)) }
            connected.remove(id)
            withContext(Dispatchers.IO) { vault.remove(id) }
        }

    fun stop() {
        process?.destroy()
        base = ""
        connected.clear()
    }
}

fun mimeFor(name: String): String? =
    when (name.substringAfterLast('.').lowercase()) {
        "jpg",
        "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        "heic",
        "heif" -> "image/heif"
        "avif" -> "image/avif"
        "bmp" -> "image/bmp"
        "mp4",
        "m4v" -> "video/mp4"
        "mov" -> "video/quicktime"
        "mkv" -> "video/x-matroska"
        "webm" -> "video/webm"
        else -> null
    }

suspend fun Call.await(): Response = suspendCancellableCoroutine { c ->
    c.invokeOnCancellation { cancel() }
    enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (c.isActive) c.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                c.resume(response) { _, value, _ -> value.close() }
            }
        }
    )
}
