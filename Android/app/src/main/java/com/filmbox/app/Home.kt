@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package com.filmbox.app

import android.Manifest
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlin.math.abs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun FilmboxRoot(graph: AppGraph, actions: MediaActions) {
    val s by graph.ui.collectAsStateWithLifecycle()
    val activity = LocalActivity.current
    val dark = s.theme == "dark" || (s.theme == "system" && isSystemInDarkTheme())
    LaunchedEffect(activity, dark) {
        activity?.let {
            val bars = WindowCompat.getInsetsController(it.window, it.window.decorView)
            bars.isAppearanceLightStatusBars = !dark
            bars.isAppearanceLightNavigationBars = !dark
        }
    }
    FilmTheme(s.theme) { Box(Modifier.fillMaxSize()) { Home(graph, s, actions) } }
}

@Composable
private fun Home(graph: AppGraph, s: GalleryState, actions: MediaActions) {
    val c = LocalFilm.current
    val context = LocalContext.current
    val coroutine = rememberCoroutineScope()
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val snack = remember { SnackbarHostState() }
    var scope by rememberSaveable { mutableStateOf(Scope.ALL.name) }
    var scopeId by rememberSaveable { mutableStateOf("") }
    var mode by rememberSaveable { mutableStateOf(BrowseMode.GRID.name) }
    var query by rememberSaveable { mutableStateOf("") }
    var searching by remember { mutableStateOf(false) }
    var filter by remember { mutableStateOf(Filter()) }
    var sorting by rememberSaveable { mutableStateOf(SortKey.DATE.name) }
    var descending by rememberSaveable { mutableStateOf(true) }
    var density by rememberSaveable { mutableFloatStateOf(150f) }
    var focus by rememberSaveable { mutableStateOf("") }
    var selecting by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var viewer by remember { mutableStateOf<String?>(null) }
    var viewerIds by remember { mutableStateOf(emptyList<String>()) }
    var info by remember { mutableStateOf<Media?>(null) }
    var mediaMenu by remember { mutableStateOf<List<Media>?>(null) }
    var albumPicker by remember { mutableStateOf<Set<String>?>(null) }
    var settings by remember { mutableStateOf(false) }
    var addLibrary by remember { mutableStateOf(false) }
    var reconnectAccount by remember { mutableStateOf<CloudAccount?>(null) }
    var reconnectFolder by remember { mutableStateOf<Library?>(null) }
    var filterOpen by remember { mutableStateOf(false) }
    var sortOpen by remember { mutableStateOf(false) }
    var densityOpen by remember { mutableStateOf(false) }
    var nameInitial by remember { mutableStateOf("") }
    var nameDialog by remember { mutableStateOf<Pair<String, (String) -> Unit>?>(null) }
    var libraryMenu by remember { mutableStateOf<Library?>(null) }
    var albumMenu by remember { mutableStateOf<Album?>(null) }
    var muted by rememberSaveable { mutableStateOf(true) }
    SideEffect { actions.onMessage = { text -> coroutine.launch { snack.showSnackbar(text) } } }
    val permission =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            graph.onResume()
        }
    fun askPermission() {
        permission.launch(
            if (Build.VERSION.SDK_INT >= 34)
                arrayOf(
                    Manifest.permission.READ_MEDIA_IMAGES,
                    Manifest.permission.READ_MEDIA_VIDEO,
                    Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
                )
            else if (Build.VERSION.SDK_INT >= 33)
                arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
            else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        )
    }
    val folder =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                try {
                    context.contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                    runCatching {
                        context.contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION,
                        )
                    }
                }
                val replacing = reconnectFolder
                if (replacing != null) graph.reconnectFolder(replacing.id, uri)
                else graph.addFolder(uri)
                reconnectFolder = null
                addLibrary = false
            }
        }
    SideEffect {
        graph.onRecovery = { request ->
            val library = s.libraries.firstOrNull { it.id == request.source }
            coroutine.launch {
                when (request.problem) {
                    RecoveryProblem.LOGIN -> {
                        reconnectAccount =
                            withContext(kotlinx.coroutines.Dispatchers.IO) {
                                graph.cloud.vault.accounts().firstOrNull {
                                    it.id == library?.account
                                }
                            }
                        addLibrary = true
                    }
                    RecoveryProblem.NETWORK,
                    RecoveryProblem.TIMEOUT ->
                        runCatching {
                            context.startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
                        }
                    RecoveryProblem.SERVICE,
                    RecoveryProblem.LIMITED,
                    RecoveryProblem.DENIED,
                    RecoveryProblem.SECURE -> {
                        val saved =
                            withContext(kotlinx.coroutines.Dispatchers.IO) {
                                library?.account?.let { graph.cloud.vault.read(it) }
                            }
                        val url =
                            when (saved?.optString("provider")) {
                                "quark" -> "https://pan.quark.cn"
                                "baidu" -> "https://pan.baidu.com"
                                else -> saved?.optString("endpoint").orEmpty()
                            }
                        if (url.isNotBlank())
                            runCatching {
                                context.startActivity(
                                    Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                )
                            }
                    }
                    RecoveryProblem.MISSING,
                    RecoveryProblem.INCOMPLETE -> graph.refresh(request.source)
                    RecoveryProblem.PERMISSION,
                    RecoveryProblem.OFFLINE -> {
                        if (library != null) {
                            reconnectFolder = library
                            folder.launch(android.net.Uri.parse(library.uri))
                        } else askPermission()
                    }
                    RecoveryProblem.STORAGE -> settings = true
                    RecoveryProblem.UNSUPPORTED -> request.media?.let { actions.openExternal(it) }
                    RecoveryProblem.ENGINE,
                    RecoveryProblem.UNKNOWN -> {
                        context
                            .getSystemService(android.content.ClipboardManager::class.java)
                            .setPrimaryClip(
                                android.content.ClipData.newPlainText(
                                    "Filmbox 诊断",
                                    "Filmbox Android ${BuildConfig.VERSION_NAME}\ncode=${request.problem.code}\nsource=${if(library?.cloud == true)"cloud" else "local"}",
                                )
                            )
                        snack.showSnackbar("诊断信息已复制")
                    }
                }
            }
        }
    }
    val shown =
        remember(s.items, scope, scopeId, query, filter, sorting, descending, s.cacheRevision) {
            val list =
                s.items
                    .filter { m ->
                        val inScope =
                            when (Scope.valueOf(scope)) {
                                Scope.ALL -> !m.hidden
                                Scope.HIDDEN -> m.hidden
                                Scope.FAVORITES -> m.favorite && !m.hidden
                                Scope.ALBUM -> scopeId in m.albums && !m.hidden
                                Scope.LIBRARY -> m.source in scopeId.split('|') && !m.hidden
                            }
                        inScope &&
                            (query.isBlank() ||
                                m.name.contains(query, true) ||
                                m.folder.contains(query, true)) &&
                            filter.matches(
                                m,
                                if (filter.download == 0) false else graph.isDownloaded(m),
                            )
                    }
                    .distinctBy { it.identityKey }
            val comparator =
                when (SortKey.valueOf(sorting)) {
                    SortKey.DATE -> compareBy<Media> { it.date }.thenBy { it.name }
                    SortKey.NAME -> compareBy<Media> { it.name.lowercase() }
                    SortKey.SIZE -> compareBy<Media> { it.size }.thenBy { it.name }
                }
            list.sortedWith(if (descending) comparator.reversed() else comparator)
        }
    LaunchedEffect(shown, selecting) {
        if (selecting) {
            val visible =
                withContext(kotlinx.coroutines.Dispatchers.Default) {
                    shown.map { it.id }.toHashSet()
                }
            selected = selected.intersect(visible)
        }
    }
    val title =
        when (Scope.valueOf(scope)) {
            Scope.ALL -> "所有项目"
            Scope.HIDDEN -> "隐藏"
            Scope.FAVORITES -> "收藏"
            Scope.ALBUM -> s.albums.firstOrNull { it.id == scopeId }?.name ?: "影集"
            Scope.LIBRARY ->
                if (scopeId == "gallery") "手机相册"
                else if (scopeId.contains('|')) "所选资源库"
                else s.libraries.firstOrNull { it.id == scopeId }?.name ?: "资源库"
        }
    fun navigate(next: Scope, id: String = "") {
        scope = next.name
        scopeId = id
        selected = emptySet()
        selecting = false
        coroutine.launch { drawer.close() }
    }
    fun toggleLibrary(id: String) {
        val allIds = (s.libraries.map { it.id } + "gallery").toSet()
        val current =
            if (scope == Scope.ALL.name) allIds
            else if (scope == Scope.LIBRARY.name)
                scopeId.split('|').filter { it.isNotBlank() }.toSet()
            else emptySet()
        val next = if (id in current) current - id else current + id
        scope = Scope.LIBRARY.name
        scopeId = next.joinToString("|")
        selected = emptySet()
    }
    fun pick(m: Media) {
        if (selecting) selected = if (m.id in selected) selected - m.id else selected + m.id
        else {
            focus = m.id
            viewerIds = shown.map { it.id }
            viewer = m.id
        }
    }
    BackHandler(selecting) {
        selecting = false
        selected = emptySet()
    }
    val sidebarContent: @Composable () -> Unit = {
        Column(Modifier.fillMaxHeight()) {
            Row(
                Modifier.padding(24.dp).padding(top = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FilmLogo()
                Text(
                    "filmbox",
                    fontSize = 27.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = (-1).sp,
                )
            }
            Column(
                Modifier.weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 14.dp)
            ) {
                DrawerRow(
                    Icons.Outlined.PhotoLibrary,
                    "所有项目",
                    s.items.count { !it.hidden }.toString(),
                    scope == Scope.ALL.name,
                ) {
                    navigate(Scope.ALL)
                }
                DrawerRow(
                    Icons.Outlined.FavoriteBorder,
                    "收藏",
                    s.items.count { it.favorite && !it.hidden }.toString(),
                    scope == Scope.FAVORITES.name,
                ) {
                    navigate(Scope.FAVORITES)
                }
                DrawerRow(
                    Icons.Outlined.VisibilityOff,
                    "隐藏",
                    s.items.count { it.hidden }.toString(),
                    scope == Scope.HIDDEN.name,
                ) {
                    navigate(Scope.HIDDEN)
                }
                DrawerSection("影集") {
                    nameInitial = ""
                    nameDialog = "新建影集" to { graph.createAlbum(it) }
                }
                s.albums.forEach { a ->
                    DrawerRow(
                        Icons.Outlined.CollectionsBookmark,
                        a.name,
                        s.items.count { a.id in it.albums && !it.hidden }.toString(),
                        scope == Scope.ALBUM.name && scopeId == a.id,
                        onLongClick = { albumMenu = a },
                    ) {
                        navigate(Scope.ALBUM, a.id)
                    }
                }
                DrawerSection("资源库") { addLibrary = true }
                DrawerRow(
                    Icons.Outlined.PhoneAndroid,
                    "手机相册",
                    if ("gallery" in s.scanning) null
                    else s.items.count { it.source == "gallery" }.toString(),
                    scope == Scope.ALL.name ||
                        (scope == Scope.LIBRARY.name && "gallery" in scopeId.split('|')),
                    busy = "gallery" in s.scanning,
                    onToggle = { toggleLibrary("gallery") },
                ) {
                    navigate(Scope.LIBRARY, "gallery")
                }
                s.libraries.forEach { l ->
                    DrawerRow(
                        if (l.cloud) Icons.Outlined.CloudQueue else Icons.Outlined.Folder,
                        l.name,
                        if (l.id in s.scanning) null
                        else s.items.count { it.source == l.id }.toString(),
                        scope == Scope.ALL.name ||
                            (scope == Scope.LIBRARY.name && l.id in scopeId.split('|')),
                        onToggle = { toggleLibrary(l.id) },
                        busy = l.id in s.scanning,
                        error = s.problems[l.id],
                        onLongClick = { libraryMenu = l },
                    ) {
                        navigate(Scope.LIBRARY, l.id)
                    }
                }
                if (s.partial)
                    FilmTextButton(onClick = { askPermission() }) {
                        Text("管理照片访问权限", fontSize = 12.sp)
                    }
            }
            Row(
                Modifier.fillMaxWidth().padding(14.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                FilmIcon(Icons.Outlined.Settings, "设置") {
                    settings = true
                    coroutine.launch { drawer.close() }
                }
                FilmIcon(Icons.Outlined.Refresh, "刷新") { graph.refreshAll() }
            }
        }
    }
    val galleryContent: @Composable () -> Unit = {
        Scaffold(
            containerColor = c.canvas,
            snackbarHost = {},
            bottomBar = {
                if (viewer == null && selecting)
                    Column(Modifier.background(c.panel).navigationBarsPadding()) {
                        if (selecting) {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                                horizontalArrangement = Arrangement.SpaceAround,
                            ) {
                                FilmIcon(Icons.Outlined.SelectAll, "全选") {
                                    selected =
                                        if (selected.size == shown.size) emptySet()
                                        else shown.map { it.id }.toSet()
                                }
                                FilmIcon(
                                    Icons.Outlined.IosShare,
                                    "分享",
                                    enabled = selected.isNotEmpty(),
                                ) {
                                    actions.share(shown.filter { it.id in selected })
                                }
                                FilmIcon(
                                    Icons.Outlined.ContentCopy,
                                    "复制",
                                    enabled = selected.isNotEmpty(),
                                ) {
                                    actions.copy(shown.filter { it.id in selected })
                                }
                                FilmIcon(
                                    Icons.Outlined.LibraryAdd,
                                    "添加到影集",
                                    enabled = selected.isNotEmpty(),
                                ) {
                                    albumPicker = selected
                                }
                                FilmIcon(
                                    Icons.Outlined.MoreHoriz,
                                    "更多",
                                    enabled = selected.isNotEmpty(),
                                ) {
                                    mediaMenu = shown.filter { it.id in selected }
                                }
                            }
                        }
                    }
            },
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding)) {
                Row(
                    Modifier.fillMaxWidth()
                        .background(c.panel)
                        .padding(horizontal = 8.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp < 840)
                        FilmIcon(Icons.Outlined.Menu, "资源库") { coroutine.launch { drawer.open() } }
                    else FilmLogo(Modifier.padding(horizontal = 8.dp))
                    if (searching)
                        FilmTextField(
                            query,
                            { query = it },
                            Modifier.weight(1f),
                            placeholder = { Text("搜索", fontSize = 14.sp) },
                            singleLine = true,
                            shape = CircleShape,
                            trailingIcon = {
                                FilmIcon(Icons.Outlined.Close, "关闭搜索") {
                                    searching = false
                                    query = ""
                                }
                            },
                        )
                    else {
                        Column(Modifier.weight(1f).padding(start = 8.dp)) {
                            Text(
                                if (selecting) "已选择 ${selected.size} 项" else title,
                                fontWeight = FontWeight.Bold,
                                fontSize = 18.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Text("${shown.size} 个项目", fontSize = 11.sp, color = c.secondary)
                                if (s.downloads > 0) {
                                    FilmSpinner(Modifier.size(10.dp), strokeWidth = 1.dp)
                                    Text(
                                        "${s.downloads} 项下载中",
                                        fontSize = 11.sp,
                                        color = c.secondary,
                                    )
                                }
                            }
                        }
                        FilmIcon(Icons.Outlined.Search, "搜索") { searching = true }
                    }
                    FilmIcon(
                        if (selecting) Icons.Outlined.CheckCircle
                        else Icons.Outlined.CheckCircleOutline,
                        if (selecting) "完成选择" else "多选",
                        active = selecting,
                    ) {
                        selecting = !selecting
                        if (!selecting) selected = emptySet()
                    }
                }
                Row(
                    Modifier.fillMaxWidth()
                        .background(c.panel)
                        .padding(start = 12.dp, end = 8.dp, bottom = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    listOf("全部", "照片", "视频").forEachIndexed { i, text ->
                        FilterPill(text, filter.type == i) { filter = filter.copy(type = i) }
                    }
                    FilmIcon(Icons.AutoMirrored.Outlined.Sort, "筛选", active = filter.count > 0) {
                        filterOpen = true
                    }
                    Spacer(Modifier.weight(1f))
                    FilmIcon(Icons.Outlined.SwapVert, "排序") { sortOpen = true }
                    FilmIcon(
                        if (mode == BrowseMode.GRID.name) Icons.Outlined.ViewStream
                        else Icons.Outlined.ViewCarousel,
                        "切换浏览模式",
                        active = true,
                    ) {
                        mode =
                            if (mode == BrowseMode.GRID.name) BrowseMode.REEL.name
                            else BrowseMode.GRID.name
                    }
                }
                val issueSource =
                    s.issues.keys.firstOrNull {
                        scope != Scope.LIBRARY.name || it in scopeId.split('|')
                    }
                if (issueSource != null) {
                    val issue = s.issues.getValue(issueSource)
                    Row(
                        Modifier.fillMaxWidth()
                            .background(c.panel)
                            .padding(horizontal = 16.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "${s.libraries.firstOrNull { it.id == issueSource }?.name ?: "手机相册"} · ${issue.title}",
                            Modifier.weight(1f),
                            fontSize = 12.sp,
                            color = c.secondary,
                        )
                        FilmTextButton(onClick = { graph.recover(issue, issueSource) }) {
                            Text(issue.action, fontSize = 12.sp)
                        }
                    }
                }
                IndexActivityCard(s)
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    if (shown.isEmpty())
                        EmptyGallery(
                            s,
                            scope,
                            scopeId,
                            filter,
                            query,
                            onPermission = { askPermission() },
                            onClear = {
                                filter = Filter()
                                query = ""
                            },
                            onAdd = { addLibrary = true },
                            onRefresh = {
                                val source =
                                    if (scope == Scope.LIBRARY.name) scopeId.split('|').first()
                                    else "gallery"
                                val issue = s.issues[source]
                                if (issue != null) graph.recover(issue, source)
                                else graph.refresh(source)
                            },
                        )
                    else if (mode == BrowseMode.GRID.name)
                        PhotoGalleryGrid(
                            shown,
                            density,
                            selecting,
                            selected,
                            focus,
                            onFocus = { focus = it },
                            onClick = { pick(it) },
                            onLongClick = {
                                selecting = true
                                selected = selected + it.id
                            },
                            onDensityChange = { density = it },
                            browseActive = viewer == null && !settings,
                            graph = graph,
                        )
                    else
                        PhotoReel(
                            shown,
                            focus,
                            { focus = it },
                            onClick = { pick(it) },
                            onLongClick = {
                                selecting = true
                                selected = selected + it.id
                            },
                            selected = selected,
                            selecting = selecting,
                            graph = graph,
                            muted = muted,
                            onMute = { muted = it },
                            autoplay = s.autoplay && viewer == null && !settings,
                            browseActive = viewer == null && !settings,
                            cacheRevision = s.cacheRevision,
                            density = density,
                        )
                }
            }
        }
    }
    Box(
        Modifier.fillMaxSize()
            .then(if (settings || viewer != null) Modifier.clearAndSetSemantics {} else Modifier)
    ) {
        if (androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp >= 840) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet(
                        drawerContainerColor = c.panel,
                        modifier = Modifier.width(270.dp),
                    ) {
                        sidebarContent()
                    }
                }
            ) {
                galleryContent()
            }
        } else {
            ModalNavigationDrawer(
                drawerState = drawer,
                drawerContent = {
                    ModalDrawerSheet(
                        drawerContainerColor = c.panel,
                        modifier = Modifier.width(292.dp),
                    ) {
                        sidebarContent()
                    }
                },
                gesturesEnabled = viewer == null,
            ) {
                galleryContent()
            }
        }
    }

    val viewerItems =
        remember(s.items, viewerIds, scope) {
            val current = if (viewerIds.isEmpty()) emptyMap() else s.items.associateBy { it.id }
            viewerIds
                .mapNotNull { current[it] }
                .filter { if (scope == Scope.HIDDEN.name) it.hidden else !it.hidden }
        }
    if (viewer != null)
        MediaViewer(
            viewerItems,
            viewer!!,
            {
                viewer = it
                focus = it
            },
            onClose = {
                viewer = null
                viewerIds = emptyList()
            },
            graph = graph,
            actions = actions,
            muted = muted,
            onMute = { muted = it },
            onMenu = { mediaMenu = listOf(it) },
            onInfo = { info = it },
        )
    if (info != null) MediaInfo(info!!, graph) { info = null }
    if (mediaMenu != null)
        MediaMenu(
            mediaMenu!!,
            actions,
            graph,
            onDismiss = { mediaMenu = null },
            onAlbum = { albumPicker = it },
            onRename = { m ->
                nameInitial = m.name.substringBeforeLast('.', m.name)
                nameDialog = "重命名" to { actions.rename(m, it) }
            },
            onInfo = { info = it },
            currentAlbum = if (scope == Scope.ALBUM.name) scopeId else null,
        )
    if (albumPicker != null)
        AlbumPicker(
            s.albums,
            onDismiss = { albumPicker = null },
            onPick = {
                graph.albumAdd(it, albumPicker!!)
                albumPicker = null
            },
            onCreate = { name ->
                graph.createAlbum(name, albumPicker!!)
                albumPicker = null
            },
        )
    if (settings)
        SettingsPage(graph, s, onClose = { settings = false }, onAddCloud = { addLibrary = true })
    if (addLibrary)
        AddLibrarySheet(
            graph,
            onClose = {
                addLibrary = false
                reconnectAccount = null
            },
            initialReconnect = reconnectAccount,
            onLocal = { folder.launch(null) },
            onGallery = {
                askPermission()
                addLibrary = false
            },
        )
    if (filterOpen)
        FilterSheet(
            filter,
            shownFormats = s.items.map { it.format }.toSet().sorted(),
            onChange = { filter = it },
            onClose = { filterOpen = false },
        )
    if (sortOpen)
        FilmSheet(onDismissRequest = { sortOpen = false }) {
            Column(Modifier.padding(horizontal = 20.dp).navigationBarsPadding()) {
                Text(
                    "排序",
                    fontSize = 21.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(bottom = 16.dp),
                )
                listOf(SortKey.DATE to "拍摄时间", SortKey.NAME to "名称", SortKey.SIZE to "大小")
                    .forEach { (key, label) ->
                        FilmListItem(
                            headlineContent = { Text(label) },
                            trailingContent = {
                                if (sorting == key.name)
                                    Icon(Icons.Outlined.Check, null, tint = c.accent)
                            },
                            modifier =
                                Modifier.clip(RoundedCornerShape(14.dp))
                                    .background(
                                        if (sorting == key.name) c.raised else Color.Transparent
                                    )
                                    .clickable {
                                        sorting = key.name
                                        sortOpen = false
                                    },
                        )
                    }
                FilmListItem(
                    headlineContent = {
                        Text(if (mode == BrowseMode.REEL.name) "时间轴密度" else "浏览密度")
                    },
                    leadingContent = { Icon(Icons.Outlined.Tune, null) },
                    modifier =
                        Modifier.clickable {
                            sortOpen = false
                            densityOpen = true
                        },
                )
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilmButton(
                        if (sorting == SortKey.DATE.name) "从新到旧" else "降序",
                        selected = descending,
                        modifier = Modifier.weight(1f),
                    ) {
                        descending = true
                    }
                    FilmButton(
                        if (sorting == SortKey.DATE.name) "从旧到新" else "升序",
                        selected = !descending,
                        modifier = Modifier.weight(1f),
                    ) {
                        descending = false
                    }
                }
            }
        }
    if (densityOpen)
        FilmSheet(onDismissRequest = { densityOpen = false }, containerColor = c.panel) {
            Column(Modifier.padding(24.dp).navigationBarsPadding()) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (mode == BrowseMode.REEL.name) "时间轴密度" else "浏览密度",
                        Modifier.weight(1f),
                        fontWeight = FontWeight.Bold,
                    )
                    FilmIcon(Icons.Outlined.Close, "关闭密度设置") { densityOpen = false }
                }
                Spacer(Modifier.height(16.dp))
                val reel = mode == BrowseMode.REEL.name
                FilmSlider(
                    density.coerceIn(if (reel) 80f else 12f, if (reel) 240f else 360f),
                    { density = if (reel) it else snapGalleryDensity(it) },
                    valueRange = if (reel) 80f..240f else 12f..360f,
                )
                Text(
                    if (reel) {
                        if (density < 110) "按月" else if (density < 140) "按周" else "按天"
                    } else
                        when (galleryDateLevel(density)) {
                            3 -> "按年"
                            2 -> "按月"
                            1 -> "按周"
                            else -> "按天"
                        },
                    fontSize = 12.sp,
                    color = c.secondary,
                )
                Spacer(Modifier.height(20.dp))
            }
        }
    nameDialog?.let { (title, save) ->
        NameDialog(title, initial = nameInitial, onDismiss = { nameDialog = null }) { text ->
            save(text)
            nameDialog = null
        }
    }
    libraryMenu?.let { l ->
        SimpleMenu(
            l.name,
            onDismiss = { libraryMenu = null },
            entries =
                listOf(
                    "重新加载" to { graph.refresh(l.id) },
                    "重命名" to
                        {
                            nameInitial = l.name
                            nameDialog = "资源库名称" to { graph.renameLibrary(l.id, it) }
                        },
                    "上移" to { graph.moveLibrary(l.id, -1) },
                    "下移" to { graph.moveLibrary(l.id, 1) },
                    "移除资源库" to { graph.removeLibrary(l.id) },
                ),
        )
    }
    albumMenu?.let { a ->
        SimpleMenu(
            a.name,
            onDismiss = { albumMenu = null },
            entries =
                listOf(
                    "重命名" to
                        {
                            nameInitial = a.name
                            nameDialog = "影集名称" to { graph.renameAlbum(a.id, it) }
                        },
                    "删除影集" to { graph.deleteAlbum(a.id) },
                ),
        )
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        SnackbarHost(
            snack,
            Modifier.windowInsetsPadding(
                    mediaOverlayInsets()
                        .only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)
                )
                .padding(horizontal = 16.dp)
                .padding(
                    bottom =
                        if (viewer != null) {
                            if (viewerItems.firstOrNull { it.id == viewer }?.video == true) 196.dp
                            else 128.dp
                        } else if (selecting) 64.dp else 16.dp
                ),
        )
    }
}

@Composable
fun FilterPill(text: String, selected: Boolean, onClick: () -> Unit) {
    FilmButton(text, selected = selected, onClick = onClick)
}

@Composable
private fun DrawerSection(text: String, onAdd: () -> Unit) {
    val c = LocalFilm.current
    Row(
        Modifier.fillMaxWidth().padding(start = 14.dp, top = 20.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, Modifier.weight(1f), color = c.secondary, fontSize = 12.sp)
        FilmIcon(Icons.Outlined.Add, "添加$text", onClick = onAdd)
    }
}

@Composable
private fun DrawerRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
    count: String?,
    active: Boolean,
    busy: Boolean = false,
    error: String? = null,
    onToggle: (() -> Unit)? = null,
    onLongClick: () -> Unit = {},
    onClick: () -> Unit,
) {
    val c = LocalFilm.current
    Column(
        Modifier.fillMaxWidth()
            .padding(vertical = 4.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(if (active) FilmBlue.copy(alpha = .13f) else Color.Transparent)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 14.dp, vertical = 12.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(11.dp),
        ) {
            if (onToggle != null)
                Icon(
                    if (active) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                    "选择$text",
                    Modifier.size(20.dp).clickable { onToggle() },
                    tint = if (active) c.accent else c.secondary,
                )
            Icon(icon, null, Modifier.size(18.dp), tint = if (active) c.accent else c.secondary)
            Text(
                text,
                Modifier.weight(1f),
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (busy) FilmSpinner(Modifier.size(12.dp), strokeWidth = 1.5.dp)
            else count?.let { Text(it, fontSize = 11.sp, color = c.secondary) }
        }
        if (error != null)
            Text(
                error,
                Modifier.padding(start = 29.dp, top = 6.dp),
                fontSize = 11.sp,
                color = c.secondary,
            )
    }
}

@Composable
private fun EmptyGallery(
    s: GalleryState,
    scope: String,
    id: String,
    filter: Filter,
    query: String,
    onPermission: () -> Unit,
    onClear: () -> Unit,
    onAdd: () -> Unit,
    onRefresh: () -> Unit,
) {
    val c = LocalFilm.current
    val busy =
        if (scope == Scope.LIBRARY.name) id.split('|').any { it in s.scanning && it !in s.issues }
        else s.scanning.isNotEmpty()
    val problem =
        if (scope == Scope.LIBRARY.name) id.split('|').firstNotNullOfOrNull { s.problems[it] }
        else null
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (busy) FilmSpinner(Modifier.size(28.dp), strokeWidth = 2.dp, color = c.secondary)
        else
            Icon(
                if (problem != null) Icons.Outlined.FolderOff else Icons.Outlined.PhotoLibrary,
                null,
                Modifier.size(38.dp),
                tint = c.secondary,
            )
        Spacer(Modifier.height(20.dp))
        Text(
            when {
                busy -> if (s.libraries.any { it.id == id && it.cloud }) "正在建立云端索引" else "正在整理照片"
                problem != null -> problem
                query.isNotBlank() || filter.count > 0 -> "没有符合条件的项目"
                !s.permission && s.libraries.isEmpty() -> "尚未添加照片"
                else -> "暂无项目"
            },
            fontSize = 16.sp,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.height(18.dp))
        if (query.isNotBlank() || filter.count > 0) FilmButton("清除筛选", onClick = onClear)
        else if (problem != null) FilmButton(s.issues[id]?.action ?: "查看问题", onClick = onRefresh)
        else if (!s.permission) {
            FilmButton("访问手机相册", selected = true, onClick = onPermission)
            Spacer(Modifier.height(10.dp))
            FilmTextButton(onClick = onAdd) { Text("添加资源库", color = c.secondary) }
        } else if (!busy) FilmButton("添加资源库", onClick = onAdd)
    }
}

@Composable
fun MediaTile(
    m: Media,
    graph: AppGraph,
    modifier: Modifier = Modifier,
    selecting: Boolean = false,
    selected: Boolean = false,
    large: Boolean = false,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val c = LocalFilm.current
    val context = LocalContext.current
    val coroutine = rememberCoroutineScope()
    val state by graph.ui.collectAsStateWithLifecycle()
    val quality = graph.previewQuality(m)
    var model by remember(m.revision, quality, state.cacheEpoch) { mutableStateOf<Any?>(null) }
    var failure by remember(m.revision, quality, state.cacheEpoch) { mutableStateOf<String?>(null) }
    var ready by remember(m.revision, quality, state.cacheEpoch) { mutableStateOf(false) }
    LaunchedEffect(m.revision, quality, state.cacheEpoch, state.problems[m.source]) {
        failure = null
        try {
            model = graph.preview(m)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            failure = if (e is CloudFailure) e.message else "无法加载"
        }
    }
    Box(
        modifier
            .clip(RoundedCornerShape(2.dp))
            .background(c.raised)
            .semantics(mergeDescendants = true) {
                contentDescription = m.name
                role = Role.Button
            }
            .combinedClickable(onClick = onClick, onLongClick = onLongClick),
        contentAlignment = Alignment.Center,
    ) {
        if (model != null)
            AsyncImage(
                ImageRequest.Builder(context)
                    .data(model)
                    .memoryCacheKey("preview:${m.revision}:$quality:${state.cacheEpoch}")
                    .diskCacheKey("preview:${m.revision}")
                    .apply { if (large) size(1600) }
                    .build(),
                null,
                Modifier.fillMaxSize()
                    .then(
                        if (large && m.cloud && !graph.isDownloaded(m)) Modifier.blur(12.dp)
                        else Modifier
                    ),
                contentScale = ContentScale.Fit,
                onSuccess = { result ->
                    ready = true
                    val d = result.result.drawable
                    if (m.width == 0 && d.intrinsicWidth > 0)
                        coroutine.launch {
                            graph.updateDimensions(m, d.intrinsicWidth, d.intrinsicHeight)
                        }
                },
                onError = { failure = "无法加载" },
            )
        if (!ready) {
            if (m.cloud && failure == null)
                FilmSpinner(
                    Modifier.size(if (large) 22.dp else 15.dp),
                    strokeWidth = 1.5.dp,
                    color = c.secondary,
                )
            else
                Icon(
                    if (failure == null) Icons.Outlined.Image else Icons.Outlined.BrokenImage,
                    null,
                    Modifier.size(24.dp),
                    tint = c.secondary.copy(alpha = .6f),
                )
        }
        if (m.video)
            Row(
                Modifier.align(Alignment.BottomEnd).padding(7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.PlayArrow, null, Modifier.size(15.dp), tint = Color.White)
                if (m.duration > 0)
                    Text(
                        "${m.duration/60000}:${(m.duration/1000%60).toString().padStart(2,'0')}",
                        fontSize = 10.sp,
                        color = Color.White,
                    )
            }
        if (m.cloud)
            Icon(
                if (graph.isDownloaded(m)) Icons.Outlined.CloudDone else Icons.Outlined.CloudQueue,
                "云端",
                Modifier.align(Alignment.BottomStart).padding(7.dp).size(14.dp),
                tint = Color.White.copy(alpha = .8f),
            )
        if (selecting)
            Icon(
                if (selected) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                if (selected) "已选中" else "未选中",
                Modifier.align(Alignment.TopEnd)
                    .padding(8.dp)
                    .size(23.dp)
                    .background(c.panel.copy(alpha = .7f), CircleShape),
                tint = if (selected) c.accent else Color.White,
            )
    }
}

@Composable
private fun PhotoReel(
    items: List<Media>,
    focus: String,
    onFocus: (String) -> Unit,
    onClick: (Media) -> Unit,
    onLongClick: (Media) -> Unit,
    selected: Set<String>,
    selecting: Boolean,
    graph: AppGraph,
    muted: Boolean,
    onMute: (Boolean) -> Unit,
    autoplay: Boolean,
    browseActive: Boolean,
    cacheRevision: Int,
    density: Float,
) {
    val c = LocalFilm.current
    val list = rememberLazyListState()
    val coroutine = rememberCoroutineScope()
    // Keep this browsing session's geometry stable while unknown aspect ratios are discovered.
    val pixels = LocalDensity.current.density
    var viewportWidth by remember { mutableFloatStateOf(0f) }
    var viewportHeight by remember { mutableFloatStateOf(0f) }
    val ratios = remember { mutableMapOf<String, Float>() }
    items.forEach { ratios.getOrPut(it.id) { it.ratio } }
    suspend fun centerItem(i: Int, animate: Boolean = true) {
        if (i !in items.indices || viewportWidth <= 0) return
        val offset =
            (reelWidth(ratios[items[i].id] ?: 1f, viewportWidth, viewportHeight) * pixels / 2)
                .toInt()
        if (animate) list.animateScrollToItem(i, offset) else list.scrollToItem(i, offset)
    }
    var activeIndex by remember {
        mutableIntStateOf(items.indexOfFirst { it.id == focus }.coerceAtLeast(0))
    }
    var positioned by remember { mutableStateOf(false) }
    val active = items.getOrNull(activeIndex.coerceIn(0, items.lastIndex)) ?: return
    val transferState by graph.ui.collectAsStateWithLifecycle()
    var original by
        remember(active.revision, browseActive) { mutableStateOf(graph.original(active)) }
    var failed by remember(active.revision, browseActive) { mutableStateOf<RecoveryProblem?>(null) }
    LaunchedEffect(items.map { it.id }, viewportWidth, viewportHeight, browseActive) {
        if (!browseActive) return@LaunchedEffect
        if (viewportWidth <= 0) return@LaunchedEffect
        val i = items.indexOfFirst { it.id == focus }.coerceAtLeast(0)
        activeIndex = i
        centerItem(i, false)
        positioned = true
    }
    LaunchedEffect(list, items, positioned) {
        if (positioned)
            snapshotFlow {
                    focusedIndex(
                        list.layoutInfo.visibleItemsInfo.map {
                            it.index to (it.offset + it.size / 2f)
                        },
                        (list.layoutInfo.viewportStartOffset + list.layoutInfo.viewportEndOffset) /
                            2f,
                    )
                }
                .distinctUntilChanged()
                .collect { i ->
                    if (i != null && i in items.indices) {
                        activeIndex = i
                        onFocus(items[i].id)
                    }
                }
    }
    LaunchedEffect(active.revision, browseActive) {
        if (!browseActive) return@LaunchedEffect
        original = graph.original(active)
        failed = null
        if (active.cloud && !active.video && original == null) {
            try {
                original = graph.download(active)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failed = graph.problem(e, active)
            }
        }
    }
    Column(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val height = maxHeight.value
            val width = maxWidth.value
            SideEffect {
                viewportWidth = width
                viewportHeight = height
            }
            LazyRow(
                state = list,
                flingBehavior = rememberSnapFlingBehavior(list),
                modifier = Modifier.fillMaxSize(),
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
                contentPadding = PaddingValues(horizontal = (width / 2).dp),
            ) {
                itemsIndexed(items, key = { _, m -> m.id }) { i, m ->
                    val ratio = ratios[m.id] ?: 1f
                    val w = reelWidth(ratio, width, height)
                    val h = (w / ratio).coerceAtMost(height)
                    Box(Modifier.width(w.dp).height(h.dp)) {
                        if (i == activeIndex && m.video && autoplay && !selecting)
                            FilmVideo(
                                m,
                                graph,
                                muted,
                                onMute,
                                Modifier.fillMaxSize(),
                                controls = false,
                            )
                        else if (i == activeIndex && original != null && !m.video)
                            AsyncImage(
                                original,
                                m.name,
                                Modifier.fillMaxSize()
                                    .combinedClickable(
                                        onClick = { onClick(m) },
                                        onLongClick = { onLongClick(m) },
                                    ),
                                contentScale = ContentScale.Fit,
                            )
                        else
                            MediaTile(
                                m,
                                graph,
                                Modifier.fillMaxSize(),
                                selecting,
                                m.id in selected,
                                large = true,
                                onClick = { onClick(m) },
                                onLongClick = { onLongClick(m) },
                            )
                        if (i == activeIndex && m.video && autoplay && !selecting)
                            Box(
                                Modifier.matchParentSize()
                                    .combinedClickable(
                                        onClick = { onClick(m) },
                                        onLongClick = { onLongClick(m) },
                                    )
                            )
                        if (
                            i == activeIndex &&
                                browseActive &&
                                active.cloud &&
                                active.revision in transferState.originalTransfers
                        )
                            LoadingBadge(
                                "正在下载",
                                Modifier.align(Alignment.BottomCenter).padding(16.dp),
                            )
                        if (i == activeIndex && failed != null)
                            RecoveryNotice(
                                failed!!,
                                Modifier.align(Alignment.BottomCenter).padding(16.dp),
                            ) {
                                graph.recover(failed!!, active.source, active)
                            }
                    }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilmIcon(
                Icons.AutoMirrored.Outlined.KeyboardArrowLeft,
                "上一项",
                enabled = activeIndex > 0,
            ) {
                coroutine.launch { centerItem((activeIndex - 1).coerceAtLeast(0)) }
            }
            Column(
                Modifier.weight(1f)
                    .combinedClickable(
                        onClick = { onClick(active) },
                        onLongClick = { onLongClick(active) },
                    )
            ) {
                Text(active.name, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(dateText(active.date), fontSize = 10.sp, color = c.secondary)
            }
            if (active.video)
                FilmIcon(
                    if (muted) Icons.AutoMirrored.Outlined.VolumeOff
                    else Icons.AutoMirrored.Outlined.VolumeUp,
                    "静音",
                    active = !muted,
                ) {
                    onMute(!muted)
                }
            FilmIcon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                "下一项",
                enabled = activeIndex < items.lastIndex,
            ) {
                coroutine.launch { centerItem((activeIndex + 1).coerceAtMost(items.lastIndex)) }
            }
        }
        DateWheel(
            items,
            active.date,
            false,
            Modifier.fillMaxWidth().height(70.dp),
            level = if (density < 110) 2 else if (density < 140) 1 else 0,
        ) { date ->
            val i = items.indexOfFirst { it.date == date }
            if (i >= 0) coroutine.launch { centerItem(i) }
        }
    }
}

@Composable
private fun DateWheel(
    items: List<Media>,
    active: Long,
    vertical: Boolean,
    modifier: Modifier,
    level: Int = 0,
    onDate: (Long) -> Unit,
) {
    val c = LocalFilm.current
    val counts =
        remember(items, level) { items.groupingBy { groupKey(it.date, level) }.eachCount() }
    val dates =
        remember(items, level) { items.distinctBy { groupKey(it.date, level) }.map { it.date } }
    val index =
        dates.indexOfFirst { groupKey(it, level) == groupKey(active, level) }.coerceAtLeast(0)
    val state = rememberLazyListState()
    val coroutine = rememberCoroutineScope()
    LaunchedEffect(index, level) {
        if (!state.isScrollInProgress) state.animateScrollToItem((index - 2).coerceAtLeast(0))
    }
    @Composable
    fun tick(i: Int, date: Long) {
        val activeTick = i == index
        val distance = abs(i - index)
        val alpha = if (activeTick) 1f else (1f - distance * .11f).coerceIn(.35f, .8f)
        Column(
            Modifier.width(
                    if (vertical) 34.dp
                    else timelineExtent(counts[groupKey(date, level)] ?: 1, false).dp
                )
                .height(
                    if (vertical) timelineExtent(counts[groupKey(date, level)] ?: 1, true).dp
                    else 63.dp
                )
                .alpha(alpha)
                .clickable { onDate(date) }
                .padding(top = 5.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box(
                Modifier.width(if (vertical) 12.dp else 1.dp)
                    .height(if (vertical) 1.dp else if (activeTick) 13.dp else 8.dp)
                    .background(if (activeTick) c.accent else c.secondary)
            )
            Spacer(Modifier.height(5.dp))
            Text(
                dateText(date, if (level == 2) "M月" else if (vertical) "M/d" else "M月d日"),
                fontSize = if (vertical) 9.sp else 10.sp,
                color = if (activeTick) c.accent else c.secondary,
                fontWeight = if (activeTick) FontWeight.Bold else FontWeight.Normal,
            )
            if (activeTick || (i > 0 && dateText(dates[i - 1], "yyyy") != dateText(date, "yyyy")))
                Text(
                    dateText(date, "yyyy"),
                    fontSize = 8.sp,
                    color = if (activeTick) c.accent else c.secondary,
                )
        }
    }
    Box(modifier.background(c.panel)) {
        if (vertical)
            LazyColumn(
                state = state,
                contentPadding = PaddingValues(vertical = 100.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.fillMaxSize(),
            ) {
                itemsIndexed(dates) { i, d -> tick(i, d) }
            }
        else
            LazyRow(
                state = state,
                flingBehavior = rememberSnapFlingBehavior(state),
                contentPadding = PaddingValues(horizontal = 60.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                itemsIndexed(dates) { i, d -> tick(i, d) }
            }
        val brush =
            if (vertical)
                Brush.verticalGradient(
                    listOf(c.panel, Color.Transparent, Color.Transparent, c.panel)
                )
            else
                Brush.horizontalGradient(
                    listOf(c.panel, Color.Transparent, Color.Transparent, c.panel)
                )
        Box(Modifier.matchParentSize().background(brush))
    }
}
