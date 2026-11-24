@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    kotlinx.coroutines.FlowPreview::class,
)

package com.filmbox.app

import android.os.SystemClock
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

@Composable
fun PhotoGalleryGrid(
    items: List<Media>,
    density: Float,
    selecting: Boolean,
    selected: Set<String>,
    focus: String,
    onFocus: (String) -> Unit,
    onClick: (Media) -> Unit,
    onLongClick: (Media) -> Unit,
    onDensityChange: (Float) -> Unit,
    browseActive: Boolean,
    graph: AppGraph,
) {
    val c = LocalFilm.current
    val context = LocalContext.current
    val pixels = LocalDensity.current.density
    val coroutine = rememberCoroutineScope()
    val state by graph.ui.collectAsStateWithLifecycle()
    val viewport = remember { GalleryViewport() }
    var data by remember { mutableStateOf<GalleryData?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var visualDensity by remember { mutableFloatStateOf(density.coerceIn(12f, 360f)) }
    var pinching by remember { mutableStateOf(false) }
    var settling by remember { mutableStateOf(false) }
    var scrolling by remember { mutableStateOf(false) }
    var settleJob by remember { mutableStateOf<Job?>(null) }
    var ratioFrom by remember { mutableStateOf<FloatArray?>(null) }
    var ratioProgress by remember { mutableFloatStateOf(1f) }
    var width by remember { mutableFloatStateOf(0f) }
    var height by remember { mutableFloatStateOf(0f) }
    val previews =
        remember(graph) {
            GalleryPreviews(context, graph, coroutine, { pinching || settling || scrolling })
        }
    var drawTime by remember { mutableLongStateOf(SystemClock.uptimeMillis()) }
    DisposableEffect(previews) { onDispose { previews.close() } }
    LaunchedEffect(previews.version) {
        val start = SystemClock.uptimeMillis()
        animate(0f, 220f, animationSpec = tween(220, easing = LinearEasing)) { elapsed, _ ->
            drawTime = start + elapsed.toLong()
        }
    }
    val latestClick by rememberUpdatedState(onClick)
    val latestLongClick by rememberUpdatedState(onLongClick)
    val latestSelecting by rememberUpdatedState(selecting)
    val latestDensityChange by rememberUpdatedState(onDensityChange)
    fun update(target: Float, pivot: GalleryPivot?) {
        val current = data ?: return
        visualDensity = target.coerceIn(12f, 360f)
        viewport.reset(current, visualDensity, width, height, pivot, ratioFrom, ratioProgress)
        revision++
    }
    suspend fun alignEdges() {
        val correction = viewport.edgeAdjustment()
        if (abs(correction) < .5f) return
        var previous = 0f
        animate(0f, correction, animationSpec = tween(220, easing = FastOutSlowInEasing)) { value, _
            ->
            viewport.adjust(value - previous)
            previous = value
            revision++
        }
    }
    fun settle(
        target: Float,
        startPivot: GalleryPivot? = viewport.anchorAt(width / 2, height / 2),
    ) {
        settleJob?.cancel()
        settling = true
        val start = visualDensity
        settleJob =
            coroutine.launch {
                try {
                    animate(
                        start,
                        target,
                        animationSpec = spring(stiffness = 550f, dampingRatio = .92f),
                    ) { value, _ ->
                        update(value, startPivot?.copy(height = startPivot.height * value / start))
                    }
                    update(target, startPivot?.copy(height = startPivot.height * target / start))
                    alignEdges()
                    latestDensityChange(target)
                } finally {
                    if (settleJob === currentCoroutineContext()[Job]) settling = false
                }
            }
    }
    val scroll = rememberScrollableState { delta ->
        if (pinching || settling) 0f
        else {
            val consumed = viewport.scroll(delta / pixels)
            if (consumed != 0f) revision++
            consumed * pixels
        }
    }
    LaunchedEffect(scroll) { snapshotFlow { scroll.isScrollInProgress }.collect { scrolling = it } }
    LaunchedEffect(density) {
        if (!pinching && !settling && abs(density - visualDensity) > .5f)
            settle(snapGalleryDensity(density))
    }
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
        val w = maxWidth.value
        val h = maxHeight.value
        SideEffect {
            width = w
            height = h
        }
        LaunchedEffect(items, w, h, browseActive, pinching, settling, scrolling) {
            if (!browseActive || pinching || settling || scrolling || w <= 0 || h <= 0)
                return@LaunchedEffect
            val old = data
            if (
                old?.items == items &&
                    viewport.width == w &&
                    viewport.height == h &&
                    ratioProgress >= 1f
            )
                return@LaunchedEffect
            if (old != null) delay(100)
            val next = withContext(Dispatchers.Default) { GalleryData(items, old) }
            val oldPivot = viewport.anchorAt(w / 2, h * .4f)
            val oldId = oldPivot?.let { old?.items?.getOrNull(it.index)?.id } ?: focus
            val index = next.byId[oldId]
            val pivot =
                if (index != null)
                    oldPivot?.copy(index = index)
                        ?: GalleryPivot(index, .5f, .5f, w / 2, h / 2, visualDensity)
                else null
            val from = if (next.sameOrder) viewport.ratiosNow() else null
            val changed =
                from != null && next.ratios.indices.any { abs(from[it] - next.ratios[it]) > .002f }
            data = next
            ratioFrom = if (changed) from else null
            ratioProgress = if (changed) 0f else 1f
            update(visualDensity, pivot)
            if (changed)
                animate(0f, 1f, animationSpec = tween(260, easing = FastOutSlowInEasing)) { value, _
                    ->
                    ratioProgress = value
                    update(visualDensity, pivot)
                }
            ratioFrom = null
            ratioProgress = 1f
            alignEdges()
        }
        val window = remember(revision) { viewport.window() }
        val current = data
        val visible =
            remember(window, h) { window.tiles.filter { it.bounds.bottom > 0 && it.bounds.y < h } }
        LaunchedEffect(focus, browseActive, current) {
            if (
                browseActive &&
                    !pinching &&
                    !settling &&
                    current != null &&
                    visible.none { current.items[it.index].id == focus }
            ) {
                current.byId[focus]?.let {
                    update(visualDensity, GalleryPivot(it, .5f, .5f, w / 2, h / 2, visualDensity))
                }
            }
        }
        LaunchedEffect(window.tiles.map { it.index }, browseActive) {
            if (
                browseActive &&
                    !pinching &&
                    !settling &&
                    current != null &&
                    visible.none { current.items[it.index].id == focus }
            ) {
                visible
                    .minByOrNull { hypot(it.bounds.centerX - w / 2, it.bounds.centerY - h / 2) }
                    ?.let { onFocus(current.items[it.index].id) }
            }
        }
        LaunchedEffect(browseActive, state.cacheEpoch, state.cacheRevision, state.problems) {
            previews.resetFailures()
            if (!browseActive) {
                previews.request(null, GalleryWindow(), w, h, pixels, state.cacheEpoch)
                return@LaunchedEffect
            }
            // sample keeps making progress during scrolling; debounce used to starve fast gestures.
            snapshotFlow { revision }
                .sample(70)
                .collect {
                    previews.request(data, viewport.window(), w, h, pixels, state.cacheEpoch)
                }
        }
        val latestWindow by rememberUpdatedState(window)
        val latestData by rememberUpdatedState(current)
        fun hit(point: Offset) =
            latestWindow.tiles.firstOrNull {
                it.bounds.contains(point.x / pixels, point.y / pixels)
            }
        val dateMode =
            when (galleryDateLevel(visualDensity)) {
                3 -> "按年"
                2 -> "按月"
                1 -> "按周"
                else -> "按天"
            }
        val interactive =
            Modifier.fillMaxSize()
                .semantics {
                    contentDescription = "照片流"
                    stateDescription = "$dateMode · ${current?.items?.size ?: 0} 项"
                    progressBarRangeInfo = ProgressBarRangeInfo(visualDensity, 12f..360f)
                    setProgress { requested ->
                        settle(snapGalleryDensity(requested))
                        true
                    }
                    verticalScrollAxisRange =
                        ScrollAxisRange(
                            { window.offset.coerceAtLeast(0f) },
                            { window.extent.coerceAtLeast(h) },
                        )
                    scrollBy { _, y ->
                        coroutine.launch { scroll.scroll { scrollBy(-y) } }
                        true
                    }
                }
                .scrollable(scroll, Orientation.Vertical, enabled = !pinching && !settling)
                .pointerInput(Unit) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                        var started = false
                        var base = visualDensity
                        var factor = 1f
                        var pivot: GalleryPivot? = null
                        var center = Offset.Zero
                        do {
                            val event = awaitPointerEvent(PointerEventPass.Initial)
                            if (event.changes.count { it.pressed } >= 2) {
                                val fingers = event.changes.filter { it.pressed }
                                center =
                                    Offset(
                                        fingers.sumOf { it.position.x.toDouble() }.toFloat() /
                                            fingers.size,
                                        fingers.sumOf { it.position.y.toDouble() }.toFloat() /
                                            fingers.size,
                                    ) / pixels
                                if (!started) {
                                    settleJob?.cancel()
                                    settleJob = null
                                    started = true
                                    pinching = true
                                    settling = false
                                    base = visualDensity
                                    pivot = viewport.anchorAt(center.x, center.y)
                                    pivot?.let {
                                        data?.items?.getOrNull(it.index)?.let { item ->
                                            onFocus(item.id)
                                        }
                                    }
                                }
                                factor *= event.calculateZoom()
                                val next = (base * factor).coerceIn(12f, 360f)
                                update(
                                    next,
                                    pivot?.copy(
                                        x = center.x,
                                        y = center.y,
                                        height = pivot!!.height * next / base,
                                    ),
                                )
                            }
                            if (started) event.changes.forEach { it.consume() }
                        } while (event.changes.any { it.pressed })
                        if (started) {
                            pinching = false
                            settle(
                                snapGalleryDensity(visualDensity),
                                viewport.anchorAt(center.x, center.y),
                            )
                        }
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { point ->
                            hit(point)?.let { tile ->
                                latestData?.items?.getOrNull(tile.index)?.let { media ->
                                    if (visualDensity < 50 && !latestSelecting) {
                                        val pivot =
                                            viewport.anchorAt(point.x / pixels, point.y / pixels)
                                        onFocus(media.id)
                                        settle(150f, pivot)
                                    } else latestClick(media)
                                }
                            }
                        },
                        onLongPress = { point ->
                            hit(point)?.let { tile ->
                                latestData?.items?.getOrNull(tile.index)?.let(latestLongClick)
                            }
                        },
                    )
                }
                .pointerInput(Unit) {
                    detectDragGesturesAfterLongPress(
                        onDragStart = { point ->
                            hit(point)?.let { tile ->
                                latestData?.items?.getOrNull(tile.index)?.let(latestLongClick)
                            }
                        },
                        onDrag = { change, _ ->
                            hit(change.position)?.let { tile ->
                                latestData?.items?.getOrNull(tile.index)?.let(latestLongClick)
                            }
                            val y = change.position.y / pixels
                            if (y < 48 || y > h - 48)
                                coroutine.launch {
                                    scroll.scroll {
                                        scrollBy(if (y < 48) -18 * pixels else 18 * pixels)
                                    }
                                }
                            change.consume()
                        },
                    )
                }
        val play = rememberVectorPainter(Icons.Outlined.PlayArrow)
        val cloudIcon = rememberVectorPainter(Icons.Outlined.CloudQueue)
        val doneIcon = rememberVectorPainter(Icons.Outlined.CloudDone)
        val imageIcon = rememberVectorPainter(Icons.Outlined.Image)
        Canvas(interactive) {
            // Reading this revision invalidates the draw, not the geometry engine.
            val imageVersion = previews.version
            val now = drawTime
            if (current != null)
                visible.forEach { tile ->
                    val m = current.items[tile.index]
                    val rect = tile.bounds
                    val x = rect.x * pixels
                    val y = rect.y * pixels
                    val width = rect.width * pixels
                    val height = rect.height * pixels
                    drawRect(
                        c.raised,
                        Offset(x, y),
                        androidx.compose.ui.geometry.Size(width, height),
                    )
                    val entry = previews.get(m, state.cacheEpoch)
                    if (entry != null) {
                        val fade = ((now - entry.readyAt) / 180f).coerceIn(0f, 1f)
                        val eased = 1 - (1 - fade).pow(3)
                        fun photo(bitmap: androidx.compose.ui.graphics.ImageBitmap, alpha: Float) {
                            val ratio = bitmap.width.toFloat() / bitmap.height
                            val dw = min(width, height * ratio)
                            val dh = dw / ratio
                            drawImage(
                                bitmap,
                                dstOffset =
                                    IntOffset(
                                        (x + (width - dw) / 2).roundToInt(),
                                        (y + (height - dh) / 2).roundToInt(),
                                    ),
                                dstSize =
                                    IntSize(
                                        dw.roundToInt().coerceAtLeast(1),
                                        dh.roundToInt().coerceAtLeast(1),
                                    ),
                                alpha = alpha,
                            )
                        }
                        entry.previous?.let { photo(it.asImageBitmap(), 1f) }
                        photo(entry.image, eased)
                    } else if (
                        rect.width > 48 &&
                            rect.height > 48 &&
                            !(m.cloud && previews.loading(m, state.cacheEpoch))
                    ) {
                        val size = 20 * pixels
                        withTransform({
                            translate(x + (width - size) / 2, y + (height - size) / 2)
                        }) {
                            with(imageIcon) {
                                draw(
                                    androidx.compose.ui.geometry.Size(size, size),
                                    alpha = .3f,
                                    colorFilter = ColorFilter.tint(c.secondary),
                                )
                            }
                        }
                    }
                    if (!pinching && !settling && rect.width >= 60 && rect.height >= 60) {
                        val size = 13 * pixels
                        if (m.video)
                            withTransform({
                                translate(
                                    x + width - size - 5 * pixels,
                                    y + height - size - 5 * pixels,
                                )
                            }) {
                                with(play) {
                                    draw(
                                        androidx.compose.ui.geometry.Size(size, size),
                                        colorFilter = ColorFilter.tint(Color.White),
                                    )
                                }
                            }
                        if (m.cloud)
                            withTransform({
                                translate(x + 5 * pixels, y + height - size - 5 * pixels)
                            }) {
                                with(if (graph.isDownloaded(m)) doneIcon else cloudIcon) {
                                    draw(
                                        androidx.compose.ui.geometry.Size(size, size),
                                        alpha = .8f,
                                        colorFilter = ColorFilter.tint(Color.White),
                                    )
                                }
                            }
                    }
                    if (selecting) {
                        val radius = min(10 * pixels, min(width, height) / 4)
                        val center =
                            Offset(x + width - radius - 3 * pixels, y + radius + 3 * pixels)
                        drawCircle(
                            if (m.id in selected) c.accent else c.panel.copy(alpha = .8f),
                            radius,
                            center,
                        )
                        if (m.id in selected) {
                            drawLine(
                                Color.White,
                                center + Offset(-radius * .45f, 0f),
                                center + Offset(-radius * .1f, radius * .35f),
                                radius * .2f,
                            )
                            drawLine(
                                Color.White,
                                center + Offset(-radius * .1f, radius * .35f),
                                center + Offset(radius * .5f, -radius * .4f),
                                radius * .2f,
                            )
                        }
                    }
                }
            window.dates
                .mapNotNull { it.dividerY }
                .forEach { y ->
                    drawLine(
                        c.line.copy(alpha = .6f),
                        Offset(12 * pixels, y * pixels),
                        Offset(size.width - 12 * pixels, y * pixels),
                        pixels * .5f,
                    )
                }
        }
        if (current != null) {
            val previewVersion = previews.version
            if (!pinching && !settling)
                visible.forEach { tile ->
                    val m = current.items[tile.index]
                    val rect = tile.bounds
                    if (
                        m.cloud &&
                            rect.width >= 60 &&
                            rect.height >= 60 &&
                            previews.get(m, state.cacheEpoch) == null &&
                            previews.loading(m, state.cacheEpoch)
                    )
                        key(m.id) {
                            GalleryCloudProgress(
                                Modifier.offset {
                                        IntOffset(
                                            ((rect.centerX - 9) * pixels).roundToInt(),
                                            ((rect.centerY - 9) * pixels).roundToInt(),
                                        )
                                    }
                                    .size(18.dp)
                            )
                        }
                }
            if (visualDensity >= 50)
                visible.forEach { tile ->
                    val m = current.items[tile.index]
                    Box(
                        Modifier.offset {
                                IntOffset(
                                    (tile.bounds.x * pixels).roundToInt(),
                                    (tile.bounds.y * pixels).roundToInt(),
                                )
                            }
                            .size(tile.bounds.width.dp, tile.bounds.height.dp)
                            .semantics {
                                contentDescription = m.name
                                role = Role.Button
                                this.selected = m.id in selected
                                onClick {
                                    latestClick(m)
                                    true
                                }
                                onLongClick {
                                    latestLongClick(m)
                                    true
                                }
                            }
                    )
                }
            window.dates.forEach { date ->
                Text(
                    date.title,
                    Modifier.offset {
                            IntOffset((12 * pixels).roundToInt(), (date.y * pixels).roundToInt())
                        }
                        .widthIn(max = (w - 24).dp)
                        .animateContentSize()
                        .background(c.panel.copy(alpha = .94f), RoundedCornerShape(18.dp))
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                        .semantics { contentDescription = "日期：${date.title}" },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = c.text,
                )
            }
        }
    }
}

/** Only active network jobs animate; tiny overview cells and local reads stay quiet. */
@Composable
private fun GalleryCloudProgress(modifier: Modifier) {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(160)
        visible = true
    }
    if (visible) FilmSpinner(modifier.semantics { contentDescription = "正在加载缩略图" })
}
