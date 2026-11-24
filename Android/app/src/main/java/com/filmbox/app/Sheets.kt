@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.filmbox.app

import android.net.Uri
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

@Composable
fun NameDialog(
    title: String,
    initial: String = "",
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    FilmDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, fontSize = 18.sp) },
        text = {
            FilmTextField(text, { text = it }, singleLine = true, shape = RoundedCornerShape(12.dp))
        },
        confirmButton = {
            FilmTextButton(onClick = { onSave(text.trim()) }, enabled = text.isNotBlank()) {
                Text("保存")
            }
        },
        dismissButton = { FilmTextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
fun SimpleMenu(title: String, onDismiss: () -> Unit, entries: List<Pair<String, () -> Unit>>) {
    FilmSheet(onDismissRequest = onDismiss, containerColor = LocalFilm.current.panel) {
        Text(
            title,
            Modifier.padding(horizontal = 24.dp, vertical = 12.dp),
            fontWeight = FontWeight.Bold,
            fontSize = 17.sp,
        )
        entries.forEach { (label, action) ->
            FilmListItem(
                headlineContent = { Text(label, fontSize = 14.sp) },
                modifier =
                    Modifier.clickable {
                        onDismiss()
                        action()
                    },
            )
        }
        Spacer(Modifier.navigationBarsPadding().height(12.dp))
    }
}

@Composable
fun MediaMenu(
    items: List<Media>,
    actions: MediaActions,
    graph: AppGraph,
    onDismiss: () -> Unit,
    onAlbum: (Set<String>) -> Unit,
    onRename: (Media) -> Unit,
    onInfo: (Media) -> Unit,
    currentAlbum: String? = null,
) {
    val m = items.firstOrNull() ?: return
    val ids = items.map { it.id }.toSet()
    val entries =
        buildList<Pair<String, () -> Unit>> {
            add("分享" to { actions.share(items) })
            add("复制" to { actions.copy(items) })
            add(
                (if (items.all { it.favorite }) "取消收藏" else "收藏") to
                    {
                        graph.mark(ids, favorite = !items.all { it.favorite })
                    }
            )
            add("添加到影集" to { onAlbum(ids) })
            if (currentAlbum != null) add("从影集中移除" to { graph.albumAdd(currentAlbum, ids, false) })
            add(
                (if (items.all { it.hidden }) "取消隐藏" else "隐藏") to
                    {
                        graph.mark(ids, hidden = !items.all { it.hidden })
                    }
            )
            if (items.size == 1) {
                add("信息" to { onInfo(m) })
                add("打开方式" to { actions.openExternal(m) })
                if (!m.cloud) add("重命名" to { onRename(m) })
            }
            if (items.any { it.cloud })
                add(
                    "下载原图" to
                        {
                            graph.scope.launch {
                                items
                                    .filter { it.cloud }
                                    .forEach { runCatching { graph.download(it) } }
                            }
                        }
                )
            if (items.all { !it.cloud }) add("移到回收站" to { actions.trash(items) })
        }
    SimpleMenu(if (items.size == 1) m.name else "已选择 ${items.size} 项", onDismiss, entries)
}

@Composable
fun AlbumPicker(
    albums: List<Album>,
    onDismiss: () -> Unit,
    onPick: (String) -> Unit,
    onCreate: (String) -> Unit,
) {
    var create by remember { mutableStateOf(false) }
    FilmSheet(onDismissRequest = onDismiss, containerColor = LocalFilm.current.panel) {
        Column(Modifier.padding(horizontal = 24.dp).navigationBarsPadding()) {
            Text("添加到影集", fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(12.dp))
            FilmButton("新建影集", icon = Icons.Outlined.Add) { create = true }
            Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())) {
                albums.forEach { a ->
                    FilmListItem(
                        headlineContent = { Text(a.name) },
                        leadingContent = { Icon(Icons.Outlined.CollectionsBookmark, null) },
                        modifier = Modifier.clickable { onPick(a.id) },
                    )
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
    if (create) NameDialog("新建影集", onDismiss = { create = false }, onSave = onCreate)
}

@Composable
fun MediaInfo(m: Media, graph: AppGraph, onClose: () -> Unit) {
    val c = LocalFilm.current
    var size by
        remember(m.revision) {
            mutableStateOf(if (m.dimensionsVerified && m.width > 0) m.width to m.height else null)
        }
    LaunchedEffect(m.revision) { size = graph.originalDimensions(m) }
    FilmSheet(onDismissRequest = onClose, containerColor = c.panel) {
        Column(
            Modifier.padding(24.dp).verticalScroll(rememberScrollState()).navigationBarsPadding()
        ) {
            Text(m.name, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(20.dp))
            listOf(
                    "类型" to if (m.video) "视频 · ${m.format}" else "照片 · ${m.format}",
                    "大小" to bytesText(m.size),
                    "尺寸" to (size?.let { "${it.first} × ${it.second}" } ?: "—"),
                    "日期" to dateText(m.date, "yyyy年M月d日 HH:mm"),
                    "来源" to if (m.cloud) "云端 · ${m.folder}" else m.folder.ifBlank { "手机相册" },
                    "原图" to if (m.cloud) if (graph.original(m) != null) "已下载" else "未下载" else "本地",
                )
                .forEach { (k, v) ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                        Text(k, Modifier.width(64.dp), fontSize = 13.sp, color = c.secondary)
                        Text(v, fontSize = 13.sp)
                    }
                }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
fun FilterSheet(
    filter: Filter,
    shownFormats: List<String>,
    onChange: (Filter) -> Unit,
    onClose: () -> Unit,
) {
    val c = LocalFilm.current
    FilmSheet(onDismissRequest = onClose, containerColor = c.panel) {
        Column(
            Modifier.padding(24.dp).verticalScroll(rememberScrollState()).navigationBarsPadding()
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("筛选", Modifier.weight(1f), fontSize = 21.sp, fontWeight = FontWeight.Bold)
                FilmTextButton(onClick = { onChange(Filter()) }) { Text("重置") }
                FilmIcon(Icons.Outlined.Close, "关闭筛选", onClick = onClose)
            }
            @Composable
            fun group(label: String, values: List<String>, selected: Int, choose: (Int) -> Unit) {
                Text(
                    label,
                    Modifier.padding(top = 20.dp, bottom = 10.dp),
                    fontSize = 12.sp,
                    color = c.secondary,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    values.forEachIndexed { i, text ->
                        FilmButton(text, selected == i) { choose(i) }
                    }
                }
            }
            group("类型", listOf("全部", "照片", "视频"), filter.type) { onChange(filter.copy(type = it)) }
            group("来源", listOf("全部", "本地", "云端"), filter.source) {
                onChange(filter.copy(source = it))
            }
            group("云端原图", listOf("全部", "已下载", "未下载"), filter.download) {
                onChange(filter.copy(download = it))
            }
            Text(
                "格式",
                Modifier.padding(top = 20.dp, bottom = 10.dp),
                fontSize = 12.sp,
                color = c.secondary,
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(7.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                shownFormats.forEach { format ->
                    FilmButton(format, format in filter.formats) {
                        onChange(
                            filter.copy(
                                formats =
                                    if (format in filter.formats) filter.formats - format
                                    else filter.formats + format
                            )
                        )
                    }
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}

@Composable
fun AddLibrarySheet(
    graph: AppGraph,
    initialReconnect: CloudAccount? = null,
    onClose: () -> Unit,
    onLocal: () -> Unit,
    onGallery: () -> Unit,
) {
    val c = LocalFilm.current
    val coroutine = rememberCoroutineScope()
    var reconnecting by remember(initialReconnect) { mutableStateOf(initialReconnect) }
    var tab by remember { mutableIntStateOf(if (initialReconnect != null) 1 else 0) }
    var provider by remember { mutableStateOf(initialReconnect?.provider ?: "quark") }
    var credential by remember { mutableStateOf("") }
    var endpoint by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var web by remember { mutableStateOf(false) }
    var manual by remember { mutableStateOf(false) }
    var accounts by remember { mutableStateOf(emptyList<CloudAccount>()) }
    var account by remember { mutableStateOf<CloudAccount?>(null) }
    var folders by remember { mutableStateOf(emptyList<CloudFolder>()) }
    var path by remember { mutableStateOf(listOf<CloudFolder>()) }
    LaunchedEffect(Unit) {
        accounts = withContext(Dispatchers.IO) { graph.cloud.vault.accounts() }
        if (initialReconnect != null)
            withContext(Dispatchers.IO) { graph.cloud.vault.read(initialReconnect.id) }
                ?.let {
                    endpoint = it.optString("endpoint")
                    username = it.optString("username")
                }
    }
    fun browse(a: CloudAccount, folder: CloudFolder) {
        busy = true
        error = null
        coroutine.launch {
            try {
                val result = graph.cloud.list(a.id, folder.id, folder.path)
                folders =
                    (0 until result.length())
                        .map { result.getJSONObject(it) }
                        .filter { it.optBoolean("is_directory") }
                        .map {
                            CloudFolder(
                                it.getString("id"),
                                it.getString("name"),
                                folder.path.trimEnd('/') + "/" + it.getString("name"),
                            )
                        }
                account = a
                if (path.lastOrNull() != folder) path = path + folder
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = if (e is CloudFailure) e.message else "无法连接"
            } finally {
                busy = false
            }
        }
    }
    fun connect() {
        busy = true
        error = null
        coroutine.launch {
            try {
                val a =
                    graph.cloud.connect(
                        provider,
                        credential,
                        endpoint,
                        username,
                        password,
                        reconnecting?.id,
                    )
                accounts = accounts.filterNot { it.id == a.id } + a
                if (reconnecting != null) {
                    graph.ui.value.libraries
                        .filter { it.account == a.id }
                        .forEach { graph.refresh(it.id) }
                    onClose()
                } else {
                    path = emptyList()
                    browse(a, CloudFolder(if (provider == "quark") "0" else "/", a.name, "/"))
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = if (e is CloudFailure) e.message else "无法连接"
            } finally {
                busy = false
            }
        }
    }
    FilmSheet(onDismissRequest = { if (!web) onClose() }, containerColor = c.panel) {
        Column(
            Modifier.fillMaxWidth()
                .heightIn(max = 640.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .navigationBarsPadding()
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (reconnecting != null) "重新登录" else if (account == null) "添加资源库" else "选择文件夹",
                    Modifier.weight(1f),
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                )
                FilmIcon(Icons.Outlined.Close, "关闭", onClick = onClose)
            }
            if (account == null) {
                if (reconnecting == null)
                    Row(
                        Modifier.padding(vertical = 20.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FilmButton("本地", tab == 0) { tab = 0 }
                        FilmButton("云盘", tab == 1) { tab = 1 }
                    }
                if (tab == 0) {
                    Text("手机相册", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text(
                        "选择允许访问的照片和视频。",
                        Modifier.padding(top = 8.dp, bottom = 16.dp),
                        fontSize = 13.sp,
                        color = c.secondary,
                    )
                    FilmButton(
                        "选择照片",
                        selected = true,
                        icon = Icons.Outlined.PhotoLibrary,
                        onClick = onGallery,
                    )
                    HorizontalDivider(Modifier.padding(vertical = 24.dp), color = c.line)
                    Text("文件夹", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text(
                        "在系统文件选择器中选取一个文件夹。",
                        Modifier.padding(top = 8.dp, bottom = 16.dp),
                        fontSize = 13.sp,
                        color = c.secondary,
                    )
                    FilmButton("选择文件夹", icon = Icons.Outlined.FolderOpen, onClick = onLocal)
                } else {
                    if (accounts.isNotEmpty() && reconnecting == null) {
                        Text("已连接的账号", fontSize = 12.sp, color = c.secondary)
                        accounts.forEach { a ->
                            FilmListItem(
                                headlineContent = { Text(a.name) },
                                leadingContent = { Icon(Icons.Outlined.CloudQueue, null) },
                                modifier =
                                    Modifier.clickable {
                                        path = emptyList()
                                        browse(
                                            a,
                                            CloudFolder(
                                                if (a.provider == "quark") "0" else "/",
                                                a.name,
                                                "/",
                                            ),
                                        )
                                    },
                            )
                        }
                        Spacer(Modifier.height(16.dp))
                    }
                    if (reconnecting == null)
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(7.dp),
                            verticalArrangement = Arrangement.spacedBy(7.dp),
                        ) {
                            listOf("quark" to "夸克网盘", "baidu" to "百度网盘", "webdav" to "WebDAV")
                                .forEach { (p, text) ->
                                    FilmButton(text, provider == p) {
                                        provider = p
                                        error = null
                                        credential = ""
                                    }
                                }
                        }
                    else
                        Text(
                            if (provider == "webdav") "WebDAV"
                            else if (provider == "quark") "夸克网盘" else "百度网盘",
                            Modifier.padding(top = 20.dp),
                            fontSize = 14.sp,
                        )
                    Spacer(Modifier.height(22.dp))
                    if (provider == "webdav") {
                        Text(
                            if (reconnecting != null) "更新此账号的登录信息，连接后继续加载原资源库。"
                            else "填写服务商提供的 WebDAV 地址和账号，连接后选择资源库文件夹。",
                            fontSize = 13.sp,
                            color = c.secondary,
                            lineHeight = 21.sp,
                        )
                        FilmField(endpoint, { endpoint = it }, "https://…/dav/")
                        FilmField(username, { username = it }, "用户名")
                        FilmField(password, { password = it }, "密码或应用密码", secret = true)
                        Spacer(Modifier.height(14.dp))
                        FilmButton(
                            "连接",
                            selected = true,
                            enabled = !busy && endpoint.startsWith("https://"),
                        ) {
                            connect()
                        }
                    } else {
                        if(provider == "baidu") Text(
                            "百度默认授权和令牌刷新经过 api.oplist.org，会向该服务发送刷新令牌。完整说明见设置中的隐私页。",
                            fontSize = 12.sp, lineHeight = 19.sp, color = c.secondary,
                            modifier = Modifier.padding(bottom = 14.dp))
                        Text(
                            if (reconnecting != null)
                                "登录${if(provider=="quark")"夸克" else "百度"}网盘后，返回菲林盒继续加载原资源库。"
                            else "1  登录${if(provider=="quark")"夸克" else "百度"}网盘\n2  返回菲林盒，选择资源库文件夹",
                            fontSize = 14.sp,
                            lineHeight = 28.sp,
                        )
                        Spacer(Modifier.height(14.dp))
                        FilmButton(
                            "登录${if(provider=="quark")"夸克" else "百度"}网盘",
                            selected = true,
                            enabled = !busy,
                        ) {
                            web = true
                        }
                        Spacer(Modifier.height(16.dp))
                        FilmButton(if (manual) "收起手动连接" else "手动连接", icon = Icons.Outlined.Key) {
                            manual = !manual
                        }
                        if (manual) {
                            Text(
                                if (provider == "quark")
                                    "在电脑浏览器中登录 pan.quark.cn，打开开发者工具 → 网络，刷新页面。选择 pan.quark.cn 的请求，将请求头中的 Cookie 完整复制到下方。"
                                else "在 OpenList 授权页完成百度授权，将页面显示的 Refresh Token 复制到下方。",
                                Modifier.padding(vertical = 14.dp),
                                fontSize = 12.sp,
                                color = c.secondary,
                                lineHeight = 20.sp,
                            )
                            FilmField(
                                credential,
                                { credential = it },
                                if (provider == "quark") "Cookie" else "Refresh Token",
                                secret = true,
                            )
                            FilmButton(
                                "连接",
                                selected = true,
                                enabled = credential.isNotBlank() && !busy,
                            ) {
                                connect()
                            }
                        }
                    }
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    FilmIcon(Icons.Outlined.ArrowBack, "上一级", enabled = path.size > 1) {
                        if (path.size > 1) {
                            val target = path[path.lastIndex - 1]
                            path = path.dropLast(2)
                            browse(account!!, target)
                        }
                    }
                    Text(path.lastOrNull()?.path ?: "/", fontSize = 12.sp, color = c.secondary)
                }
                folders.forEach { f ->
                    FilmListItem(
                        headlineContent = { Text(f.name) },
                        leadingContent = { Icon(Icons.Outlined.Folder, null) },
                        trailingContent = { Icon(Icons.Outlined.ChevronRight, null) },
                        modifier = Modifier.clickable(enabled = !busy) { browse(account!!, f) },
                    )
                }
                if (folders.isEmpty() && !busy)
                    Text(
                        "没有子文件夹",
                        Modifier.padding(vertical = 22.dp),
                        fontSize = 13.sp,
                        color = c.secondary,
                    )
                Spacer(Modifier.height(16.dp))
                FilmButton(
                    "添加此文件夹",
                    selected = true,
                    enabled = !busy && error == null && path.isNotEmpty(),
                ) {
                    val f = path.last()
                    graph.addLibrary(
                        Library(
                            UUID.randomUUID().toString(),
                            f.name,
                            account = account!!.id,
                            folderId = f.id,
                            path = f.path,
                        )
                    )
                    onClose()
                }
            }
            if (busy)
                FilmSpinner(Modifier.padding(vertical = 16.dp).size(20.dp), strokeWidth = 2.dp)
            error?.let {
                Text(it, Modifier.padding(vertical = 16.dp), fontSize = 13.sp, color = c.secondary)
                if (it == "需要重新登录" && account != null)
                    FilmButton("重新登录", selected = true) {
                        reconnecting = account
                        provider = account!!.provider
                        account = null
                        credential = ""
                        manual = false
                        path = emptyList()
                        error = null
                    }
            }
            Spacer(Modifier.height(32.dp))
        }
    }
    if (web)
        CloudLogin(
            provider,
            onClose = { web = false },
            onCredential = {
                credential = it
                web = false
                connect()
            },
        )
}

@Composable
fun FilmField(value: String, onChange: (String) -> Unit, label: String, secret: Boolean = false) {
    FilmTextField(
        value,
        onChange,
        Modifier.fillMaxWidth().padding(vertical = 6.dp),
        placeholder = { Text(label, fontSize = 13.sp) },
        shape = RoundedCornerShape(13.dp),
        singleLine = true,
        visualTransformation =
            if (secret) PasswordVisualTransformation()
            else androidx.compose.ui.text.input.VisualTransformation.None,
    )
}

@Composable
private fun CloudLogin(provider: String, onClose: () -> Unit, onCredential: (String) -> Unit) {
    val context = LocalContext.current
    val c = LocalFilm.current
    var view by remember { mutableStateOf<WebView?>(null) }
    var message by remember { mutableStateOf("") }
    fun credentialFrom(url: String): String? =
        runCatching {
                val uri = Uri.parse(url)
                if (uri.host != "api.oplist.org" || uri.scheme != "https") return@runCatching null
                val values = mutableMapOf<String, String>()
                uri.queryParameterNames.forEach { k ->
                    uri.getQueryParameter(k)?.let { values[k] = it }
                }
                uri.fragment?.let { f ->
                    val decoded =
                        runCatching {
                                JSONObject(
                                    String(
                                        android.util.Base64.decode(
                                            f.replace('-', '+').replace('_', '/'),
                                            android.util.Base64.DEFAULT,
                                        ),
                                        Charsets.UTF_8,
                                    )
                                )
                            }
                            .getOrNull()
                    if (decoded != null)
                        decoded.keys().forEach { k -> values[k] = decoded.optString(k) }
                    else {
                        val u = Uri.parse("https://localhost/?$f")
                        u.queryParameterNames.forEach { k ->
                            u.getQueryParameter(k)?.let { values[k] = it }
                        }
                    }
                }
                if (values["driver_txt"] != "baiduyun_go") return@runCatching null
                val token =
                    values["refresh_token"] ?: values["refresh_ui"] ?: return@runCatching null
                if (token.isBlank() || token == "undefined" || token.length > 32768)
                    return@runCatching null
                JSONObject()
                    .put("refresh_token", token)
                    .apply {
                        values["access_token"]
                            ?.takeIf { it.isNotBlank() && it != "undefined" }
                            ?.let { put("access_token", it) }
                        if (
                            !values["client_key"].isNullOrBlank() &&
                                !values["secret_key"].isNullOrBlank()
                        ) {
                            put("client_id", values["client_key"])
                            put("client_secret", values["secret_key"])
                        }
                    }
                    .toString()
            }
            .getOrNull()
    Dialog(
        onDismissRequest = onClose,
        properties =
            DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Column(Modifier.fillMaxSize().background(c.panel).safeDrawingPadding()) {
            Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                FilmIcon(Icons.Outlined.Close, "关闭", onClick = onClose)
                Text(
                    "登录${if(provider=="quark")"夸克" else "百度"}网盘",
                    Modifier.weight(1f),
                    fontSize = 16.sp,
                )
                FilmTextButton(
                    onClick = {
                        if (provider == "quark") {
                            val cookie =
                                CookieManager.getInstance().getCookie("https://pan.quark.cn") ?: ""
                            if (cookie.contains("__puus=") || cookie.contains("__pus=")) {
                                CookieManager.getInstance().flush()
                                onCredential(cookie)
                            } else message = "请先完成登录"
                        } else {
                            val token = credentialFrom(view?.url ?: "")
                            if (token != null) onCredential(token) else message = "请完成授权，或返回使用手动连接"
                        }
                    }
                ) {
                    Text("完成登录")
                }
            }
            if (message.isNotEmpty())
                Text(
                    message,
                    Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    fontSize = 12.sp,
                    color = c.secondary,
                )
            AndroidView(
                factory = { ctx ->
                    WebView(ctx).apply {
                        view = this
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.userAgentString =
                            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
                        settings.useWideViewPort = true
                        settings.loadWithOverviewMode = true
                        settings.allowFileAccess = false
                        settings.allowContentAccess = false
                        settings.setSupportMultipleWindows(false)
                        CookieManager.getInstance().setAcceptCookie(true)
                        webViewClient =
                            object : WebViewClient() {
                                override fun onPageFinished(v: WebView?, url: String?) {
                                    if (provider == "baidu" && url != null)
                                        credentialFrom(url)?.let(onCredential)
                                }
                            }
                        val loginURL =
                            if (provider == "quark") "https://pan.quark.cn"
                            else
                                "https://api.oplist.org/#" +
                                    android.util.Base64.encodeToString(
                                        "{\"driver_txt\":\"baiduyun_go\",\"server_use\":\"true\"}"
                                            .toByteArray(),
                                        android.util.Base64.NO_WRAP,
                                    )
                        CookieManager.getInstance().removeAllCookies {
                            if(view === this) {
                                CookieManager.getInstance().flush()
                                loadUrl(loginURL)
                            }
                        }
                    }
                },
                modifier = Modifier.weight(1f),
            )
        }
        DisposableEffect(Unit) {
            onDispose {
                val old = view
                view = null
                old?.stopLoading()
                old?.clearHistory()
                old?.clearCache(true)
                old?.destroy()
                CookieManager.getInstance().removeAllCookies(null)
                CookieManager.getInstance().flush()
                android.webkit.WebStorage.getInstance().deleteAllData()
            }
        }
    }
}
