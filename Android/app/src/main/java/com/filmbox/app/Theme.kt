package com.filmbox.app

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

val FilmBlue = Color(0xFF315BFF)

@Immutable
data class FilmColors(
    val canvas: Color,
    val panel: Color,
    val raised: Color,
    val line: Color,
    val text: Color,
    val secondary: Color,
    val accent: Color,
)

val LocalFilm = staticCompositionLocalOf {
    FilmColors(
        Color(0xFF181818),
        Color(0xFF17191D),
        Color(0xFF22252B),
        Color(0xFF363A42),
        Color(0xFFF5F6F7),
        Color(0xFFA9AFBA),
        Color(0xFF8FA7FF),
    )
}

@Composable
fun FilmTheme(theme: String, content: @Composable () -> Unit) {
    val dark = theme == "dark" || (theme == "system" && isSystemInDarkTheme())
    val c =
        if (dark)
            FilmColors(
                Color(0xFF181818),
                Color(0xFF17191D),
                Color(0xFF22252B),
                Color(0xFF363A42),
                Color(0xFFF5F6F7),
                Color(0xFFA9AFBA),
                Color(0xFF8FA7FF),
            )
        else
            FilmColors(
                Color(0xFFECECEC),
                Color(0xFFF5F6F7),
                Color.White,
                Color(0xFFDCDDE0),
                Color(0xFF17191D),
                Color(0xFF616974),
                FilmBlue,
            )
    CompositionLocalProvider(LocalFilm provides c, LocalContentColor provides c.text) {
        MaterialTheme(
            colorScheme =
                (if (dark) darkColorScheme() else lightColorScheme()).copy(
                    primary = c.accent,
                    onPrimary = Color.White,
                    background = c.canvas,
                    surface = c.panel,
                    surfaceContainer = c.raised,
                    onSurface = c.text,
                    onBackground = c.text,
                    outline = c.line,
                ),
            content = content,
        )
    }
}

@Composable
fun FilmLogo(modifier: Modifier = Modifier) {
    val ink = LocalFilm.current.text
    Canvas(modifier.size(27.dp, 32.dp)) {
        val sx = size.width / 88f
        val sy = size.height / 104f
        drawRect(ink, Offset(0f, 16 * sy), Size(24 * sx, 72 * sy))
        drawRect(FilmBlue, Offset(32 * sx, 0f), Size(24 * sx, 44 * sy))
        drawRect(ink, Offset(32 * sx, 60 * sy), Size(24 * sx, 44 * sy))
        drawRect(ink, Offset(64 * sx, 16 * sy), Size(24 * sx, 72 * sy))
    }
}

@Composable
fun FilmButton(
    text: String,
    selected: Boolean = false,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val c = LocalFilm.current
    val source = remember { MutableInteractionSource() }
    val scale = filmPress(source)
    val background by
        animateColorAsState(
            if (selected) FilmBlue.copy(alpha = .17f) else c.raised,
            label = "choice",
        )
    Row(
        modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(CircleShape)
            .background(background)
            .semantics {
                role = Role.Button
                this.selected = selected
            }
            .clickable(source, indication = null, enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null)
            Icon(icon, null, Modifier.size(16.dp), tint = if (selected) c.accent else c.secondary)
        Text(
            text,
            color = (if (selected) c.accent else c.text).copy(alpha = if (enabled) 1f else .4f),
            fontSize = 12.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            maxLines = 1,
        )
    }
}

@Composable
fun FilmIcon(
    icon: ImageVector,
    label: String,
    active: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val c = LocalFilm.current
    val source = remember { MutableInteractionSource() }
    val scale = filmPress(source)
    val background by
        animateColorAsState(
            if (active) FilmBlue.copy(alpha = .17f) else Color.Transparent,
            label = "icon",
        )
    Box(
        Modifier.size(44.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(RoundedCornerShape(14.dp))
            .background(background)
            .semantics { this.selected = active }
            .clickable(
                source,
                indication = null,
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = androidx.compose.ui.Alignment.Center,
    ) {
        Icon(
            icon,
            label,
            Modifier.size(21.dp),
            tint = (if (active) c.accent else c.secondary).copy(alpha = if (enabled) 1f else .35f),
        )
    }
}
