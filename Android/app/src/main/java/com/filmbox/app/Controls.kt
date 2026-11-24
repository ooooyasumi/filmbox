@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.filmbox.app

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog

/** Shared touch feedback: restrained spring, no platform ripple or oversized control chrome. */
@Composable
fun filmPress(source: MutableInteractionSource): Float {
    val pressed by source.collectIsPressedAsState()
    return animateFloatAsState(if (pressed) .94f else 1f, spring(stiffness = 650f), label = "press")
        .value
}

@Composable
fun FilmSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
) {
    val c = LocalFilm.current
    val latest by rememberUpdatedState(onValueChange)
    val fraction =
        ((value - valueRange.start) / (valueRange.endInclusive - valueRange.start)).coerceIn(0f, 1f)
    Canvas(
        modifier
            .height(44.dp)
            .semantics {
                progressBarRangeInfo = ProgressBarRangeInfo(value, valueRange)
                setProgress {
                    latest(it.coerceIn(valueRange))
                    true
                }
            }
            .pointerInput(valueRange) {
                fun change(x: Float) {
                    latest(
                        valueRange.start +
                            ((x - 7.dp.toPx()) / (size.width - 14.dp.toPx()).coerceAtLeast(1f))
                                .coerceIn(0f, 1f) * (valueRange.endInclusive - valueRange.start)
                    )
                }
                detectTapGestures { change(it.x) }
            }
            .pointerInput(valueRange) {
                detectDragGestures(
                    onDragStart = {
                        latest(
                            valueRange.start +
                                ((it.x - 7.dp.toPx()) /
                                        (size.width - 14.dp.toPx()).coerceAtLeast(1f))
                                    .coerceIn(0f, 1f) * (valueRange.endInclusive - valueRange.start)
                        )
                    }
                ) { event, _ ->
                    latest(
                        valueRange.start +
                            ((event.position.x - 7.dp.toPx()) /
                                    (size.width - 14.dp.toPx()).coerceAtLeast(1f))
                                .coerceIn(0f, 1f) * (valueRange.endInclusive - valueRange.start)
                    )
                    event.consume()
                }
            }
    ) {
        val inset = 7.dp.toPx()
        val w = size.width - 2 * inset
        val y = size.height / 2
        drawLine(
            c.line,
            Offset(inset, y),
            Offset(size.width - inset, y),
            4.dp.toPx(),
            StrokeCap.Round,
        )
        drawLine(
            c.accent,
            Offset(inset, y),
            Offset(inset + w * fraction, y),
            4.dp.toPx(),
            StrokeCap.Round,
        )
        drawCircle(c.text, 7.dp.toPx(), Offset(inset + w * fraction, y))
    }
}

@Composable
fun FilmSwitch(checked: Boolean, onCheckedChange: ((Boolean) -> Unit)?) {
    val c = LocalFilm.current
    val x by
        animateFloatAsState(if (checked) 1f else 0f, spring(stiffness = 600f), label = "switch")
    val source = remember { MutableInteractionSource() }
    Box(
        Modifier.size(52.dp, 44.dp)
            .then(
                if (onCheckedChange == null) Modifier
                else
                    Modifier.toggleable(
                        checked,
                        interactionSource = source,
                        indication = null,
                        role = Role.Switch,
                        onValueChange = onCheckedChange,
                    )
            ),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(44.dp, 26.dp)) {
            drawRoundRect(
                if (checked) FilmBlue else c.line,
                cornerRadius = CornerRadius(size.height / 2),
            )
            drawCircle(
                Color.White,
                10.dp.toPx(),
                Offset(13.dp.toPx() + 18.dp.toPx() * x, size.height / 2),
            )
        }
    }
}

@Composable
fun FilmTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: @Composable (() -> Unit)? = null,
    singleLine: Boolean = true,
    shape: androidx.compose.ui.graphics.Shape = RoundedCornerShape(15.dp),
    trailingIcon: @Composable (() -> Unit)? = null,
    visualTransformation: VisualTransformation = VisualTransformation.None,
) {
    val c = LocalFilm.current
    BasicTextField(
        value,
        onValueChange,
        modifier.clip(shape).background(c.raised).padding(start = 16.dp, end = 8.dp),
        singleLine = singleLine,
        textStyle = TextStyle(color = c.text, fontSize = 14.sp),
        cursorBrush = SolidColor(c.accent),
        visualTransformation = visualTransformation,
        decorationBox = { inner ->
            Row(Modifier.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f).padding(vertical = 12.dp)) {
                    if (value.isEmpty())
                        CompositionLocalProvider(LocalContentColor provides c.secondary) {
                            placeholder?.invoke()
                        }
                    inner()
                }
                trailingIcon?.invoke()
            }
        },
    )
}

@Composable
fun FilmTextButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    val c = LocalFilm.current
    val source = remember { MutableInteractionSource() }
    val scale = filmPress(source)
    Row(
        modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(CircleShape)
            .clickable(
                source,
                indication = null,
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            )
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CompositionLocalProvider(
            LocalContentColor provides c.accent.copy(alpha = if (enabled) 1f else .4f)
        ) {
            content()
        }
    }
}

@Composable
fun FilmListItem(
    headlineContent: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    leadingContent: @Composable (() -> Unit)? = null,
    trailingContent: @Composable (() -> Unit)? = null,
) {
    val c = LocalFilm.current
    Row(
        modifier.fillMaxWidth().heightIn(min = 54.dp).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CompositionLocalProvider(LocalContentColor provides c.secondary) {
            leadingContent?.invoke()
        }
        Box(Modifier.weight(1f)) { headlineContent() }
        CompositionLocalProvider(LocalContentColor provides c.secondary) {
            trailingContent?.invoke()
        }
    }
}

@Composable
fun FilmSheet(
    onDismissRequest: () -> Unit,
    containerColor: Color = LocalFilm.current.panel,
    content: @Composable ColumnScope.() -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        containerColor = containerColor,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        tonalElevation = 0.dp,
        dragHandle = {
            Box(
                Modifier.padding(top = 10.dp, bottom = 16.dp)
                    .size(32.dp, 4.dp)
                    .background(LocalFilm.current.line, CircleShape)
            )
        },
        content = content,
    )
}

@Composable
fun FilmDialog(
    onDismissRequest: () -> Unit,
    title: @Composable () -> Unit,
    text: @Composable () -> Unit,
    confirmButton: @Composable () -> Unit,
    dismissButton: (@Composable () -> Unit)? = null,
) {
    val c = LocalFilm.current
    Dialog(onDismissRequest = onDismissRequest) {
        Column(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(24.dp))
                .background(c.panel)
                .padding(22.dp)
        ) {
            title()
            Spacer(Modifier.height(18.dp))
            text()
            Spacer(Modifier.height(18.dp))
            Row(
                Modifier.align(Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                dismissButton?.invoke()
                confirmButton()
            }
        }
    }
}

@Composable
fun FilmSpinner(
    modifier: Modifier = Modifier,
    strokeWidth: Dp = 1.5.dp,
    color: Color = LocalFilm.current.secondary,
) {
    val rotation by
        rememberInfiniteTransition(label = "loading")
            .animateFloat(
                0f,
                360f,
                infiniteRepeatable(tween(950, easing = LinearEasing)),
                label = "rotation",
            )
    Canvas(modifier) {
        val stroke = strokeWidth.toPx()
        drawArc(
            color.copy(alpha = .18f),
            0f,
            360f,
            false,
            topLeft = Offset(stroke, stroke),
            size =
                androidx.compose.ui.geometry.Size(
                    size.width - 2 * stroke,
                    size.height - 2 * stroke,
                ),
            style = androidx.compose.ui.graphics.drawscope.Stroke(stroke, cap = StrokeCap.Round),
        )
        drawArc(
            color,
            rotation,
            95f,
            false,
            topLeft = Offset(stroke, stroke),
            size =
                androidx.compose.ui.geometry.Size(
                    size.width - 2 * stroke,
                    size.height - 2 * stroke,
                ),
            style = androidx.compose.ui.graphics.drawscope.Stroke(stroke, cap = StrokeCap.Round),
        )
    }
}

@Composable
fun FilmProgress(modifier: Modifier = Modifier) {
    val c = LocalFilm.current
    val position by
        rememberInfiniteTransition(label = "index")
            .animateFloat(
                -.3f,
                1f,
                infiniteRepeatable(tween(1500, easing = LinearEasing)),
                label = "progress",
            )
    Canvas(modifier.fillMaxWidth().height(2.dp).clip(CircleShape)) {
        drawRect(c.line.copy(alpha = .5f))
        drawRoundRect(
            c.accent,
            Offset(size.width * position, 0f),
            androidx.compose.ui.geometry.Size(size.width * .3f, size.height),
            CornerRadius(size.height),
        )
    }
}
