@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.filmbox.app

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.distinctUntilChanged

@Composable
fun LoadingBadge(text: String, modifier: Modifier = Modifier) {
    val c = LocalFilm.current
    Row(
        modifier
            .background(c.panel.copy(alpha = .87f), CircleShape)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        FilmSpinner(Modifier.size(15.dp), strokeWidth = 1.5.dp, color = c.text)
        Text(text, fontSize = 12.sp, color = c.text, fontWeight = FontWeight.Medium)
    }
}

// Controls and notices keep their safe area even while immersive system bars animate.
@Composable
fun mediaOverlayInsets() = WindowInsets.safeDrawing.union(WindowInsets.systemBarsIgnoringVisibility)

@Composable
fun MediaViewer(
    items: List<Media>,
    id: String,
    onCurrent: (String) -> Unit,
    onClose: () -> Unit,
    graph: AppGraph,
    actions: MediaActions,
    muted: Boolean,
    onMute: (Boolean) -> Unit,
    onMenu: (Media) -> Unit,
    onInfo: (Media) -> Unit,
) {
    if (items.isEmpty()) {
        LaunchedEffect(Unit) { onClose() }
        return
    }
    val pager =
        rememberPagerState(
            initialPage = items.indexOfFirst { it.id == id }.coerceAtLeast(0),
            pageCount = { items.size },
        )
    val landscape =
        LocalConfiguration.current.orientation ==
            android.content.res.Configuration.ORIENTATION_LANDSCAPE
    var zoom by remember { mutableFloatStateOf(1f) }
    var bars by remember { mutableStateOf(!landscape) }
    val current = items[pager.currentPage.coerceIn(0, items.lastIndex)]
    LaunchedEffect(landscape) {
        bars = !landscape
        zoom = 1f
    }
    LaunchedEffect(pager, items.map { it.id }) {
        snapshotFlow { pager.currentPage }
            .distinctUntilChanged()
            .collect { page ->
                zoom = 1f
                items.getOrNull(page)?.let { onCurrent(it.id) }
            }
    }
    FilmTheme("dark") {
        Box(Modifier.fillMaxSize()) {
            val c = LocalFilm.current
            val view = LocalView.current
            val window = LocalActivity.current?.window
            val controller = window?.let { WindowCompat.getInsetsController(it, view) }
            DisposableEffect(window) {
                val lightStatus = controller?.isAppearanceLightStatusBars ?: false
                val lightNavigation = controller?.isAppearanceLightNavigationBars ?: false
                onDispose {
                    controller?.show(WindowInsetsCompat.Type.systemBars())
                    controller?.isAppearanceLightStatusBars = lightStatus
                    controller?.isAppearanceLightNavigationBars = lightNavigation
                }
            }
            SideEffect {
                controller?.systemBarsBehavior =
                    WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller?.isAppearanceLightStatusBars = false
                controller?.isAppearanceLightNavigationBars = false
                if (bars) controller?.show(WindowInsetsCompat.Type.systemBars())
                else controller?.hide(WindowInsetsCompat.Type.systemBars())
            }
            BackHandler { if (zoom > 1.01f) zoom = 1f else onClose() }
            Box(
                Modifier.fillMaxSize().background(Color(0xFF08090B)).semantics {
                    contentDescription = "媒体查看器"
                    if (!current.video) stateDescription = "${(zoom*100).toInt()}%"
                }
            ) {
                HorizontalPager(
                    state = pager,
                    userScrollEnabled = zoom <= 1.01f,
                    modifier = Modifier.fillMaxSize(),
                    beyondViewportPageCount = 0,
                    key = { items[it].id },
                ) { page ->
                    val m = items[page]
                    if (m.video && page == pager.currentPage)
                        FilmVideo(
                            m,
                            graph,
                            muted,
                            onMute,
                            Modifier.fillMaxSize(),
                            controls = true,
                            controlsVisible = bars,
                            onTap = { bars = !bars },
                            onLongClick = { onMenu(m) },
                        )
                    else if (m.video)
                        MediaTile(
                            m,
                            graph,
                            Modifier.fillMaxSize(),
                            large = true,
                            onClick = { bars = !bars },
                            onLongClick = { onMenu(m) },
                        )
                    else
                        ZoomPhoto(
                            m,
                            graph,
                            if (page == pager.currentPage) zoom else 1f,
                            onZoom = { if (page == pager.currentPage) zoom = it },
                            onTap = { bars = !bars },
                            onLongClick = { onMenu(m) },
                            focused = page == pager.currentPage,
                            controlsVisible = bars,
                        )
                }
                AnimatedVisibility(
                    bars,
                    Modifier.align(Alignment.TopCenter),
                    enter = fadeIn(tween(160)),
                    exit = fadeOut(tween(130)),
                ) {
                    Row(
                        Modifier.fillMaxWidth()
                            .background(
                                Brush.verticalGradient(
                                    listOf(Color.Black.copy(alpha = .82f), Color.Transparent)
                                )
                            )
                            .windowInsetsPadding(
                                mediaOverlayInsets()
                                    .only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)
                            )
                            .padding(horizontal = 6.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FilmIcon(Icons.Outlined.Close, "关闭查看器", onClick = onClose)
                        Column(Modifier.weight(1f).padding(horizontal = 8.dp)) {
                            Text(
                                dateText(current.date),
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                            )
                            Text(
                                "${pager.currentPage+1} / ${items.size}",
                                fontSize = 11.sp,
                                color = c.secondary,
                            )
                        }
                        FilmIcon(Icons.Outlined.Info, "信息") { onInfo(current) }
                        FilmIcon(Icons.Outlined.MoreHoriz, "更多") { onMenu(current) }
                    }
                }
                AnimatedVisibility(
                    bars,
                    Modifier.align(Alignment.BottomCenter),
                    enter = fadeIn(tween(160)) + slideInVertically { it / 3 },
                    exit = fadeOut(tween(130)) + slideOutVertically { it / 3 },
                ) {
                    Column(
                        Modifier.fillMaxWidth()
                            .background(
                                Brush.verticalGradient(
                                    listOf(Color.Transparent, Color.Black.copy(alpha = .86f))
                                )
                            )
                            .windowInsetsPadding(
                                mediaOverlayInsets()
                                    .only(WindowInsetsSides.Bottom + WindowInsetsSides.Horizontal)
                            )
                            .padding(horizontal = 12.dp, vertical = 8.dp)
                    ) {
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceAround,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            FilmIcon(Icons.Outlined.IosShare, "分享") {
                                actions.share(listOf(current))
                            }
                            FilmIcon(
                                if (current.favorite) Icons.Outlined.Favorite
                                else Icons.Outlined.FavoriteBorder,
                                "收藏",
                                active = current.favorite,
                            ) {
                                graph.mark(setOf(current.id), favorite = !current.favorite)
                            }
                            if (actions.canRotate(current)) {
                                FilmIcon(Icons.Outlined.RotateLeft, "向左旋转") {
                                    actions.rotate(current, false)
                                }
                                FilmIcon(Icons.Outlined.RotateRight, "向右旋转") {
                                    actions.rotate(current, true)
                                }
                            }
                            FilmIcon(Icons.Outlined.LibraryAdd, "添加到影集") { onMenu(current) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ZoomPhoto(
    m: Media,
    graph: AppGraph,
    zoom: Float,
    onZoom: (Float) -> Unit,
    onTap: () -> Unit,
    onLongClick: () -> Unit,
    focused: Boolean,
    controlsVisible: Boolean,
) {
    val context = LocalContext.current
    val transferState by graph.ui.collectAsStateWithLifecycle()
    var fullReady by remember(m.revision) { mutableStateOf(false) }
    var preview by remember(m.revision) { mutableStateOf<Any?>(null) }
    var full by
        remember(m.revision) {
            mutableStateOf<Any?>(if (m.cloud) graph.original(m) else Uri.parse(m.uri))
        }
    var failure by remember(m.revision) { mutableStateOf<RecoveryProblem?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    var pan by remember(m.id) { mutableStateOf(Offset.Zero) }
    LaunchedEffect(m.revision) {
        try {
            preview = graph.preview(m)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {}
    }
    LaunchedEffect(m.revision, focused, retry) {
        if (focused && m.cloud && full == null) {
            failure = null
            try {
                full = graph.download(m)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failure = graph.problem(e, m)
            }
        }
    }
    LaunchedEffect(zoom) { if (zoom <= 1f) pan = Offset.Zero }
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds(), contentAlignment = Alignment.Center) {
        val width = constraints.maxWidth.toFloat()
        val height = constraints.maxHeight.toFloat()
        LaunchedEffect(zoom, width, height, m.ratio) {
            val fitW = minOf(width, height * m.ratio)
            val fitH = minOf(height, width / m.ratio)
            val maxX = ((fitW * zoom - width) / 2).coerceAtLeast(0f)
            val maxY = ((fitH * zoom - height) / 2).coerceAtLeast(0f)
            pan = Offset(pan.x.coerceIn(-maxX, maxX), pan.y.coerceIn(-maxY, maxY))
        }
        val currentZoom by rememberUpdatedState(zoom)
        val currentPan by rememberUpdatedState(pan)
        val transform = rememberTransformableState { z, panning, _ ->
            val next = (currentZoom * z).coerceIn(1f, 5f)
            val fittedWidth = minOf(width, height * m.ratio)
            val fittedHeight = minOf(height, width / m.ratio)
            val limitX = ((fittedWidth * next - width) / 2).coerceAtLeast(0f)
            val limitY = ((fittedHeight * next - height) / 2).coerceAtLeast(0f)
            val corrected = (currentPan + panning)
            pan =
                Offset(corrected.x.coerceIn(-limitX, limitX), corrected.y.coerceIn(-limitY, limitY))
            onZoom(next)
        }
        Box(
            Modifier.fillMaxSize()
                .transformable(transform, canPan = { currentZoom > 1.01f })
                .pointerInput(m.id) {
                    detectTapGestures(
                        onTap = { onTap() },
                        onDoubleTap = { point ->
                            val next = if (currentZoom > 1.05f) 1f else 2.5f
                            val fitW = minOf(width, height * m.ratio)
                            val fitH = minOf(height, width / m.ratio)
                            val maxX = ((fitW * next - width) / 2).coerceAtLeast(0f)
                            val maxY = ((fitH * next - height) / 2).coerceAtLeast(0f)
                            pan =
                                if (next == 1f) Offset.Zero
                                else
                                    Offset(
                                        ((width / 2 - point.x) * (next - 1)).coerceIn(-maxX, maxX),
                                        ((height / 2 - point.y) * (next - 1)).coerceIn(-maxY, maxY),
                                    )
                            onZoom(next)
                        },
                        onLongPress = { onLongClick() },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            if (preview != null)
                AsyncImage(
                    preview,
                    null,
                    Modifier.fillMaxSize()
                        .blur(if (m.cloud && !fullReady) 18.dp else 0.dp)
                        .graphicsLayer {
                            scaleX = zoom
                            scaleY = zoom
                            translationX = pan.x
                            translationY = pan.y
                        },
                    contentScale = ContentScale.Fit,
                )
            if (full != null)
                AsyncImage(
                    ImageRequest.Builder(context)
                        .data(full)
                        .memoryCacheKey("full:${m.revision}:$retry")
                        .size(2560)
                        .crossfade(220)
                        .build(),
                    m.name,
                    Modifier.fillMaxSize().graphicsLayer {
                        scaleX = zoom
                        scaleY = zoom
                        translationX = pan.x
                        translationY = pan.y
                    },
                    contentScale = ContentScale.Fit,
                    onSuccess = { fullReady = true },
                    onError = { failure = RecoveryProblem.from(it.result.throwable, false) },
                )
        }
        val noticeModifier =
            Modifier.align(Alignment.BottomCenter)
                .windowInsetsPadding(
                    mediaOverlayInsets()
                        .only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)
                )
                .padding(start = 16.dp, end = 16.dp, bottom = if (controlsVisible) 76.dp else 16.dp)
        if (focused && m.cloud && m.revision in transferState.originalTransfers)
            LoadingBadge("正在下载", noticeModifier)
        val issue = failure ?: transferState.issues[m.source]?.takeIf { full == null }
        if (issue != null)
            RecoveryNotice(issue, noticeModifier) { graph.recover(issue, m.source, m) }
    }
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun FilmVideo(
    m: Media,
    graph: AppGraph,
    muted: Boolean,
    onMute: (Boolean) -> Unit,
    modifier: Modifier,
    controls: Boolean,
    controlsVisible: Boolean = true,
    onTap: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var url by
        remember(m.revision) {
            mutableStateOf<String?>(if (m.cloud) graph.original(m)?.toURI()?.toString() else m.uri)
        }
    val remoteStream = m.cloud && (url == null || url!!.startsWith("http"))
    val currentRemoteStream by rememberUpdatedState(remoteStream)
    var loading by remember { mutableStateOf(remoteStream) }
    var failure by remember(m.revision) { mutableStateOf<RecoveryProblem?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    var networkActive by remember(m.revision) { mutableStateOf(false) }
    val player =
        remember(m.revision, retry) {
            ExoPlayer.Builder(context)
                .setLoadControl(
                    DefaultLoadControl.Builder()
                        .setBufferDurationsMs(3000, 15000, 1000, 1500)
                        .setTargetBufferBytes(24 * 1024 * 1024)
                        .setPrioritizeTimeOverSizeThresholds(false)
                        .build()
                )
                .setMediaSourceFactory(
                    DefaultMediaSourceFactory(
                        DefaultDataSource.Factory(
                            context,
                            OkHttpDataSource.Factory(graph.cloud.http),
                        )
                    )
                )
                .build()
                .apply {
                    volume = if (muted) 0f else 1f
                    repeatMode = Player.REPEAT_MODE_ONE
                }
        }
    var playing by remember(player) { mutableStateOf(true) }
    var position by remember(player) { mutableLongStateOf(0L) }
    var duration by remember(player) { mutableLongStateOf(m.duration.coerceAtLeast(1L)) }
    LaunchedEffect(player, controls, controlsVisible) {
        if (controls && controlsVisible)
            while (true) {
                position = player.currentPosition.coerceAtLeast(0L)
                duration = player.duration.takeIf { it > 0 } ?: m.duration.coerceAtLeast(1L)
                playing = player.isPlaying
                kotlinx.coroutines.delay(250)
            }
    }
    LaunchedEffect(m.revision, retry) {
        failure = null
        loading = remoteStream
        try {
            if (url == null)
                url =
                    if (m.cloud)
                        graph.original(m)?.toURI()?.toString() ?: graph.cloud.resolve(m, "original")
                    else m.uri
            player.setMediaItem(androidx.media3.common.MediaItem.fromUri(url!!))
            player.prepare()
            player.playWhenReady = true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            failure = graph.problem(e, m)
            loading = false
        }
    }
    DisposableEffect(m.revision, remoteStream, networkActive) {
        if (remoteStream && networkActive) graph.streaming(1)
        onDispose { if (remoteStream && networkActive) graph.streaming(-1) }
    }
    LaunchedEffect(muted) { player.volume = if (muted) 0f else 1f }
    var resumeOnStart by remember(player) { mutableStateOf(false) }
    DisposableEffect(player, owner) {
        val listener =
            object : Player.Listener {
                override fun onIsLoadingChanged(isLoading: Boolean) {
                    networkActive = isLoading && currentRemoteStream
                }

                override fun onPlaybackStateChanged(state: Int) {
                    loading = currentRemoteStream && state == Player.STATE_BUFFERING
                }

                override fun onPlayerError(error: PlaybackException) {
                    loading = false
                    failure = graph.problem(error, m)
                    if (m.cloud)
                        graph.cloud.report(graph.cloud.accountForSource(m.source), failure!!)
                }
            }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                resumeOnStart = player.playWhenReady
                player.pause()
            } else if (event == Lifecycle.Event.ON_START && resumeOnStart && failure == null)
                player.play()
        }
        player.addListener(listener)
        owner.lifecycle.addObserver(observer)
        onDispose {
            owner.lifecycle.removeObserver(observer)
            player.removeListener(listener)
            player.release()
        }
    }
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    this.player = player
                    useController = false
                    controllerAutoShow = false
                    setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
                    setShowNextButton(false)
                    setShowPreviousButton(false)
                }
            },
            update = { it.player = player },
            modifier = Modifier.fillMaxSize(),
            onRelease = { it.player = null },
        )
        if (onTap != null)
            Box(
                Modifier.matchParentSize().pointerInput(onTap, onLongClick) {
                    detectTapGestures(onTap = { onTap() }, onLongPress = { onLongClick?.invoke() })
                }
            )
        val noticeModifier =
            Modifier.align(Alignment.BottomCenter)
                .windowInsetsPadding(
                    mediaOverlayInsets()
                        .only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)
                )
                .padding(
                    start = 16.dp,
                    end = 16.dp,
                    bottom = if (controls && controlsVisible) 140.dp else 16.dp,
                )
        if (remoteStream && loading) LoadingBadge("正在加载", noticeModifier)
        if (failure != null)
            RecoveryNotice(failure!!, noticeModifier) { graph.recover(failure!!, m.source, m) }
        AnimatedVisibility(
            controls && controlsVisible,
            Modifier.align(Alignment.BottomCenter).padding(bottom = 70.dp),
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            Row(
                Modifier.fillMaxWidth()
                    .windowInsetsPadding(
                        mediaOverlayInsets()
                            .only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)
                    )
                    .background(
                        Brush.verticalGradient(
                            listOf(Color.Transparent, Color.Black.copy(alpha = .7f))
                        )
                    )
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FilmIcon(
                    if (playing) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                    if (playing) "暂停" else "播放",
                ) {
                    if (player.playWhenReady) player.pause() else player.play()
                    playing = player.playWhenReady
                }
                Text(
                    "${position/60000}:${(position/1000%60).toString().padStart(2,'0')}",
                    fontSize = 10.sp,
                    color = Color.White,
                )
                FilmSlider(
                    position.toFloat().coerceIn(0f, duration.toFloat()),
                    {
                        player.seekTo(it.toLong())
                        position = it.toLong()
                    },
                    Modifier.weight(1f).padding(horizontal = 10.dp),
                    valueRange = 0f..duration.toFloat(),
                )
                FilmIcon(
                    if (muted) Icons.Outlined.VolumeOff else Icons.Outlined.VolumeUp,
                    "静音",
                    active = !muted,
                ) {
                    onMute(!muted)
                }
            }
        }
    }
}
