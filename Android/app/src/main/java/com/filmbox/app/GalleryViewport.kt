package com.filmbox.app

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.*

/** Date and identity work happens once, outside gesture frames. */
class GalleryData(val items: List<Media>, previous: GalleryData? = null) {
    val ratios = FloatArray(items.size) { items[it].ratio }
    val byId = items.mapIndexed { i, m -> m.id to i }.toMap()
    val sameOrder =
        previous != null &&
            items.size == previous.items.size &&
            items.indices.all {
                items[it].id == previous.items[it].id && items[it].date == previous.items[it].date
            }
    val levels: List<GalleryLevel> =
        if (sameOrder) previous!!.levels
        else {
            val dates =
                items.map {
                    if (it.date == 0L) LocalDate.MIN
                    else Instant.ofEpochMilli(it.date).atZone(ZoneId.systemDefault()).toLocalDate()
                }
            (0..3).map { level ->
                val grouped = linkedMapOf<LocalDate, MutableList<Int>>()
                dates.forEachIndexed { i, d ->
                    val key =
                        when (level) {
                            3 -> d.withDayOfYear(1)
                            2 -> d.withDayOfMonth(1)
                            1 -> d.minusDays((d.dayOfWeek.value - 1).toLong())
                            else -> d
                        }
                    grouped.getOrPut(key) { mutableListOf() }.add(i)
                }
                val order = IntArray(items.size)
                val inverse = IntArray(items.size)
                val groupAt = IntArray(items.size)
                var cursor = 0
                val groups =
                    grouped.entries.mapIndexed { g, (date, indices) ->
                        val start = cursor
                        indices.forEach { i ->
                            order[cursor] = i
                            inverse[i] = cursor
                            groupAt[cursor++] = g
                        }
                        val title =
                            if (date.year == LocalDate.MIN.year) "日期未知"
                            else
                                when (level) {
                                    3 -> "${date.year}年"
                                    2 -> "${date.year}年${date.monthValue}月"
                                    1 -> {
                                        val end = date.plusDays(6)
                                        "${date.year}年${date.monthValue}月${date.dayOfMonth}日–${end.monthValue}月${end.dayOfMonth}日"
                                    }
                                    else ->
                                        "${date.year}年${date.monthValue}月${date.dayOfMonth}日 ${listOf("周一","周二","周三","周四","周五","周六","周日")[date.dayOfWeek.value-1]}"
                                }
                        GalleryGroup(start, cursor, title)
                    }
                GalleryLevel(order, inverse, groupAt, groups)
            }
        }
}

data class GalleryGroup(val start: Int, val end: Int, val title: String)

class GalleryLevel(
    val order: IntArray,
    val inverse: IntArray,
    val groupAt: IntArray,
    val groups: List<GalleryGroup>,
)

data class GalleryBounds(val x: Float, val y: Float, val width: Float, val height: Float) {
    val right
        get() = x + width

    val bottom
        get() = y + height

    val centerX
        get() = x + width / 2

    val centerY
        get() = y + height / 2

    fun contains(x: Float, y: Float) = x in this.x..right && y in this.y..bottom
}

data class GalleryTile(val index: Int, val bounds: GalleryBounds)

data class GalleryDateBubble(val title: String, val y: Float, val dividerY: Float?)

data class GalleryPivot(
    val index: Int,
    val u: Float,
    val v: Float,
    val x: Float,
    val y: Float,
    val height: Float,
)

data class GalleryWindow(
    val tiles: List<GalleryTile> = emptyList(),
    val dates: List<GalleryDateBubble> = emptyList(),
    val offset: Float = 0f,
    val extent: Float = 0f,
)

/** Only the viewport plus two short margins exists. A pinch never walks the whole library. */
class GalleryViewport {
    private data class Row(
        val start: Int,
        val end: Int,
        val group: Int,
        val top: Float,
        val height: Float,
        val tiles: List<GalleryTile>,
    ) {
        val bottom
            get() = top + height
    }

    private var rows = ArrayDeque<Row>()
    private var offset = 0f
    private var level: GalleryLevel? = null
    var data: GalleryData? = null
        private set

    var density = 150f
        private set

    var width = 0f
        private set

    var height = 0f
        private set

    private var oldRatios: FloatArray? = null
    private var ratioProgress = 1f
    private val sectionGap = 12f
    private val margin
        get() = 84f

    private val gap
        get() = (density / 35f).coerceIn(.5f, 3f)

    private fun ratio(position: Int): Float {
        val i = level!!.order[position]
        val target = data!!.ratios[i]
        return oldRatios?.getOrNull(i)?.let { it + (target - it) * ratioProgress } ?: target
    }

    fun ratiosNow(): FloatArray? =
        data?.ratios?.let { target ->
            FloatArray(target.size) { i ->
                oldRatios?.getOrNull(i)?.let { it + (target[i] - it) * ratioProgress } ?: target[i]
            }
        }

    fun anchorAt(x: Float, y: Float): GalleryPivot? {
        val tiles = window().tiles.filter { it.bounds.bottom > 0 && it.bounds.y < height }
        val cell =
            tiles.firstOrNull { it.bounds.contains(x, y) }
                ?: tiles.minByOrNull { hypot(it.bounds.centerX - x, it.bounds.centerY - y) }
                ?: return null
        return GalleryPivot(
            cell.index,
            ((x - cell.bounds.x) / cell.bounds.width).coerceIn(0f, 1f),
            ((y - cell.bounds.y) / cell.bounds.height).coerceIn(0f, 1f),
            x,
            y,
            cell.bounds.height,
        )
    }

    fun reset(
        next: GalleryData,
        target: Float,
        width: Float,
        height: Float,
        pivot: GalleryPivot? = null,
        from: FloatArray? = null,
        progress: Float = 1f,
    ) {
        this.data = next
        this.width = width.coerceAtLeast(1f)
        this.height = height.coerceAtLeast(1f)
        density = target.coerceIn(12f, 360f)
        oldRatios = from
        ratioProgress = progress
        level = next.levels[galleryDateLevel(density)]
        rows.clear()
        offset = 0f
        if (next.items.isEmpty()) return
        val focus = pivot?.index?.takeIf { it in next.items.indices } ?: 0
        val position = level!!.inverse[focus]
        val group = level!!.groupAt[position]
        val seed =
            if (pivot == null) normalForward(position, group, sectionGap)
            else pivotRow(position, group, pivot)
        rows.add(seed)
        // Reflow must retain the finger/photo anchor, including near a source edge.
        // Normal scrolling clamps edges; doing it here makes metadata or a pinch jump.
        fill(clampEdges = pivot == null)
    }

    private fun chooseSide(
        start: Int,
        end: Int,
        space: Float,
        backwards: Boolean,
        desired: Float,
    ): Int {
        if (space <= gap || start >= end) return 0
        var sum = 0f
        var best = 0
        var score = Float.MAX_VALUE
        for (n in 1..(end - start)) {
            val p = if (backwards) end - n else start + n - 1
            sum += ratio(p)
            val h = ((space - gap * (n - 1)).coerceAtLeast(.1f)) / sum
            val distance = abs(ln(h.coerceAtLeast(.1f) / desired))
            if (distance < score) {
                score = distance
                best = n
            }
            if (h <= desired || space <= gap * n) break
        }
        return best
    }

    private fun pivotRow(position: Int, groupIndex: Int, pivot: GalleryPivot): Row {
        val group = level!!.groups[groupIndex]
        val h = pivot.height.coerceIn(2f, width / ratio(position))
        val w = h * ratio(position)
        var left = (pivot.x - w * pivot.u).coerceIn(0f, (width - w).coerceAtLeast(0f))
        if (position == group.start) left = 0f
        val leftCount = chooseSide(group.start, position, (left - gap).coerceAtLeast(0f), true, h)
        if (leftCount == 0) left = 0f
        val rightSpace = (width - left - w - gap).coerceAtLeast(0f)
        val rightCount = chooseSide(position + 1, group.end, rightSpace, false, h)
        val cells = mutableListOf<GalleryTile>()
        fun side(start: Int, end: Int, x: Float, space: Float): Float {
            if (start >= end) return 0f
            val sum = (start until end).sumOf { ratio(it).toDouble() }.toFloat()
            val sideH = ((space - gap * (end - start - 1)) / sum).coerceIn(.1f, h * 1.6f)
            var px =
                if (end == position) left - gap - (sideH * sum + gap * (end - start - 1)) else x
            for (p in start until end) {
                val cw = sideH * ratio(p)
                cells.add(GalleryTile(level!!.order[p], GalleryBounds(px, 0f, cw, sideH)))
                px += cw + gap
            }
            return sideH
        }
        val lh = side(position - leftCount, position, 0f, (left - gap).coerceAtLeast(0f))
        cells.add(GalleryTile(level!!.order[position], GalleryBounds(left, 0f, w, h)))
        val rh = side(position + 1, position + 1 + rightCount, left + w + gap, rightSpace)
        val rowH = max(h, max(lh, rh))
        val top = pivot.y - h * pivot.v - (rowH - h) / 2
        return Row(
            position - leftCount,
            position + 1 + rightCount,
            groupIndex,
            top,
            rowH,
            cells.map { cell ->
                cell.copy(bounds = cell.bounds.copy(y = (rowH - cell.bounds.height) / 2))
            },
        )
    }

    private fun normalForward(start: Int, groupIndex: Int, top: Float): Row {
        val group = level!!.groups[groupIndex]
        var end = start
        var sum = 0f
        while (end < group.end) {
            sum += ratio(end++)
            if (sum * density + gap * (end - start - 1) >= width) break
        }
        return normal(start, end, groupIndex, top, sum)
    }

    private fun normalBackward(end: Int, groupIndex: Int, bottom: Float): Row {
        val group = level!!.groups[groupIndex]
        var start = end
        var sum = 0f
        while (start > group.start) {
            sum += ratio(--start)
            if (sum * density + gap * (end - start - 1) >= width) break
        }
        val row = normal(start, end, groupIndex, 0f, sum)
        return row.copy(top = bottom - row.height)
    }

    private fun normal(start: Int, end: Int, group: Int, top: Float, sum: Float): Row {
        val fit = ((width - gap * (end - start - 1)) / sum).coerceAtLeast(.1f)
        val h = min(density, fit)
        var x = 0f
        val cells =
            (start until end).map { p ->
                val w = h * ratio(p)
                GalleryTile(level!!.order[p], GalleryBounds(x, 0f, w, h)).also { x += w + gap }
            }
        // Completed rows fill the width; short final rows retain a natural height.
        return Row(start, end, group, top, h, cells)
    }

    private fun addBefore(): Boolean {
        val first = rows.firstOrNull() ?: return false
        if (first.start == 0) return false
        val g =
            if (first.start == level!!.groups[first.group].start) first.group - 1 else first.group
        val separation = if (g == first.group) gap else sectionGap
        rows.addFirst(normalBackward(first.start, g, first.top - separation))
        return true
    }

    private fun addAfter(): Boolean {
        val last = rows.lastOrNull() ?: return false
        if (last.end == level!!.order.size) return false
        val g = if (last.end == level!!.groups[last.group].end) last.group + 1 else last.group
        rows.addLast(
            normalForward(last.end, g, last.bottom + if (g == last.group) gap else sectionGap)
        )
        return true
    }

    private fun fill(clampEdges: Boolean = true) {
        if (rows.isEmpty()) return
        repeat(2) {
            while (rows.first().top > offset - margin && addBefore()) {}
            while (rows.last().bottom < offset + height + margin && addAfter()) {}
            if (clampEdges && rows.first().start == 0 && offset < rows.first().top - sectionGap)
                offset = rows.first().top - sectionGap
            if (
                clampEdges &&
                    rows.last().end == level!!.order.size &&
                    rows.last().bottom < offset + height
            ) {
                offset = rows.last().bottom - height
                if (rows.first().start == 0) offset = max(offset, rows.first().top - sectionGap)
            }
        }
        while (rows.size > 1 && rows.elementAt(1).bottom < offset - margin) rows.removeFirst()
        while (rows.size > 1 && rows.elementAt(rows.size - 2).top > offset + height + margin) rows
            .removeLast()
    }

    fun scroll(delta: Float): Float {
        if (rows.isEmpty()) return 0f
        val old = offset
        offset -= delta
        fill()
        return old - offset
    }

    /** The correction is animated after reflow, never imposed during a finger gesture. */
    fun edgeAdjustment(): Float {
        if (rows.isEmpty()) return 0f
        var target = offset
        val first = rows.first()
        val last = rows.last()
        if (first.start == 0 && target < first.top - sectionGap) target = first.top - sectionGap
        if (last.end == level!!.order.size && last.bottom < target + height) {
            target = last.bottom - height
            if (first.start == 0) target = max(target, first.top - sectionGap)
        }
        return offset - target
    }

    fun adjust(delta: Float) {
        offset -= delta
        fill(clampEdges = false)
    }

    fun window(): GalleryWindow {
        val level = level ?: return GalleryWindow()
        if (rows.isEmpty()) return GalleryWindow()
        val tiles =
            rows.flatMap { row ->
                row.tiles.map {
                    it.copy(bounds = it.bounds.copy(y = row.top + it.bounds.y - offset))
                }
            }
        val visibleRow = rows.firstOrNull { it.bottom - offset > 10 } ?: rows.first()
        val currentGroup = visibleRow.group
        val boundaries =
            rows
                .filter { it.start == level.groups[it.group].start }
                .map { it.group to (it.top - offset - sectionGap / 2) }
        val next = boundaries.firstOrNull { it.first > currentGroup }?.second
        val sticky = min(8f, (next ?: Float.MAX_VALUE) - 34f)
        val dates = mutableListOf(GalleryDateBubble(level.groups[currentGroup].title, sticky, null))
        boundaries
            .filter { it.first > currentGroup && it.second < height }
            .forEach { (g, y) -> dates.add(GalleryDateBubble(level.groups[g].title, y + 5, y)) }
        val beforeCount = rows.first().start
        val estimated =
            (level.order.size.toFloat() / max(1, rows.sumOf { it.end - it.start }).toFloat()) *
                (rows.last().bottom - rows.first().top)
        val extent = estimated.coerceAtLeast(height)
        val progress =
            (beforeCount.toFloat() / level.order.size.coerceAtLeast(1) * extent +
                    (offset - rows.first().top))
                .coerceIn(0f, extent)
        return GalleryWindow(tiles, dates, progress, extent)
    }
}

/** Never truncate visible work. Prefetch is restricted to twelve files at either edge. */
fun galleryPreviewOrder(tiles: List<GalleryTile>, width: Float, height: Float): List<GalleryTile> {
    val visible =
        tiles
            .filter {
                it.bounds.bottom > 0 &&
                    it.bounds.y < height &&
                    it.bounds.right > 0 &&
                    it.bounds.x < width
            }
            .sortedBy {
                hypot(it.bounds.centerX.coerceAtLeast(0f), it.bounds.centerY.coerceAtLeast(0f))
            }
    val above =
        tiles.filter { it.bounds.bottom <= 0 }.sortedByDescending { it.bounds.bottom }.take(12)
    val below = tiles.filter { it.bounds.y >= height }.sortedBy { it.bounds.y }.take(12)
    return (visible + above + below).distinctBy { it.index }
}
