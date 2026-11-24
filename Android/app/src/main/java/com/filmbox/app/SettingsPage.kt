package com.filmbox.app

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SettingsPage(graph: AppGraph, s: GalleryState, onClose: () -> Unit, onAddCloud: () -> Unit) {
    val c = LocalFilm.current
    val context = LocalContext.current
    val coroutine = rememberCoroutineScope()
    var page by rememberSaveable { mutableStateOf("设置") }
    var accounts by remember { mutableStateOf(emptyList<CloudAccount>()) }
    var size by remember { mutableStateOf(0L to 0L) }
    var cacheDialog by remember { mutableStateOf(false) }
    var original by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf(true) }
    var removing by remember { mutableStateOf<CloudAccount?>(null) }
    var license by remember { mutableStateOf("") }
    var privacy by remember { mutableStateOf("") }
    var result by remember { mutableStateOf("") }
    fun back() {
        when (page) {
            "设置" -> onClose()
            "隐私",
            "开源许可" -> page = "关于"
            else -> page = "设置"
        }
    }
    BackHandler { back() }
    LaunchedEffect(page, s.libraries) {
        if (page == "云盘" || page == "设置")
            accounts = withContext(Dispatchers.IO) { graph.cloud.vault.accounts() }
        if (page == "存储") size = graph.cacheSize()
        if (page == "开源许可")
            license =
                withContext(Dispatchers.IO) {
                    listOf("Filmbox-LICENSE", "THIRD_PARTY_NOTICES.md", "Apache-LICENSE", "Go-LICENSE", "CloudEngine-LICENSE", "Mozilla-MPL-2.0.txt", "PublicSuffix-NOTICE.txt", "source-build.json").joinToString(
                        "\n\n"
                    ) {
                        context.assets.open(it).bufferedReader().use { it.readText() }
                    }
                }
        if (page == "隐私") privacy = withContext(Dispatchers.IO) {
            context.assets.open("PRIVACY.md").bufferedReader().use { it.readText() }
        }
    }
    Column(Modifier.fillMaxSize().background(c.canvas).safeDrawingPadding()) {
        Row(
            Modifier.fillMaxWidth().background(c.panel).padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilmIcon(Icons.AutoMirrored.Outlined.ArrowBack, "返回") { back() }
            Text(
                page,
                Modifier.padding(start = 8.dp),
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Column(
            Modifier.weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            when (page) {
                "设置" -> {
                    SettingsSection("显示与浏览") {
                        SettingsLink(
                            "外观",
                            Icons.Outlined.Palette,
                            value =
                                when (s.theme) {
                                    "light" -> "浅色"
                                    "dark" -> "深色"
                                    else -> "跟随系统"
                                },
                        ) {
                            page = "外观"
                        }
                        SettingsLink("浏览", Icons.Outlined.PhotoLibrary) { page = "浏览" }
                    }
                    SettingsSection("资源与存储") {
                        SettingsLink(
                            "云盘",
                            Icons.Outlined.CloudQueue,
                            value = accounts.size.takeIf { it > 0 }?.let { "$it 个账号" }.orEmpty(),
                        ) {
                            page = "云盘"
                        }
                        SettingsLink("照片访问权限", Icons.Outlined.PhotoCamera) {
                            context.startActivity(
                                Intent(
                                    android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:${context.packageName}"),
                                )
                            )
                        }
                        SettingsLink("存储", Icons.Outlined.Storage) { page = "存储" }
                    }
                    SettingsSection("其他") {
                        SettingsLink("帮助", Icons.Outlined.HelpOutline) { page = "帮助" }
                        SettingsLink("关于", Icons.Outlined.Info) { page = "关于" }
                    }
                }
                "外观" ->
                    SettingsSection("主题") {
                        listOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色").forEach {
                            (key, label) ->
                            FilmListItem(
                                headlineContent = { Text(label) },
                                trailingContent = {
                                    if (s.theme == key)
                                        Icon(Icons.Outlined.Check, null, tint = c.accent)
                                },
                                modifier =
                                    Modifier.semantics {
                                            this.selected = s.theme == key
                                            role = Role.RadioButton
                                        }
                                        .clickable { graph.settings(theme = key) },
                            )
                        }
                    }
                "浏览" -> {
                    SettingsSection("播放") {
                        SettingsToggle("自动播放视频", s.autoplay) { graph.settings(autoplay = it) }
                    }
                    SettingsSection("文件") {
                        SettingsToggle("忽略隐藏文件", s.ignoreHidden) {
                            graph.settings(ignoreHidden = it)
                        }
                    }
                }
                "云盘" -> {
                    SettingsSection("账号") {
                        accounts.forEach { account ->
                            val issue =
                                s.libraries
                                    .firstOrNull { it.account == account.id && it.id in s.problems }
                                    ?.let { s.problems[it.id] }
                            Row(
                                Modifier.fillMaxWidth()
                                    .padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(
                                    Icons.Outlined.CloudQueue,
                                    null,
                                    tint = c.secondary,
                                    modifier = Modifier.size(20.dp),
                                )
                                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                                    Text(account.name, fontSize = 14.sp)
                                    if (issue != null) {
                                        Text(issue, fontSize = 12.sp, color = c.secondary)
                                        val lib =
                                            s.libraries.first {
                                                it.account == account.id && it.id in s.problems
                                            }
                                        val problem = s.issues[lib.id] ?: RecoveryProblem.UNKNOWN
                                        FilmTextButton(
                                            onClick = { graph.recover(problem, lib.id) }
                                        ) {
                                            Text(problem.action, fontSize = 12.sp)
                                        }
                                    }
                                }
                                FilmIcon(Icons.Outlined.DeleteOutline, "移除${account.name}") {
                                    removing = account
                                }
                            }
                        }
                        SettingsLink("添加云盘", Icons.Outlined.Add) { onAddCloud() }
                    }
                }
                "存储" -> {
                    SettingsSection("缓存") {
                        SettingsValue("已下载原图", bytesText(size.first))
                        SettingsValue("预览图", bytesText(size.second))
                        SettingsValue("原图缓存上限", "2 GB")
                        SettingsLink("清除缓存", Icons.Outlined.DeleteSweep) { cacheDialog = true }
                    }
                    if (result.isNotEmpty())
                        Text(result, Modifier.padding(12.dp), fontSize = 12.sp, color = c.secondary)
                }
                "关于" -> {
                    Row(
                        Modifier.padding(vertical = 20.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        FilmLogo()
                        Column {
                            Text("菲林盒 · filmbox", fontWeight = FontWeight.Bold, fontSize = 18.sp)
                            Text(
                                "Android ${BuildConfig.VERSION_NAME}",
                                fontSize = 12.sp,
                                color = c.secondary,
                            )
                        }
                    }
                    SettingsSection("信息") {
                        SettingsLink("隐私", Icons.Outlined.Shield) { page = "隐私" }
                        SettingsLink("开源许可", Icons.Outlined.Description) { page = "开源许可" }
                        SettingsLink("导出源代码", Icons.Outlined.Code) {
                            coroutine.launch {
                                val out =
                                    withContext(Dispatchers.IO) {
                                        context.cacheDir
                                            .resolve("originals/filmbox-source.tar.gz")
                                            .apply {
                                                parentFile?.mkdirs()
                                                context.assets.open("filmbox-source.tgz").use { input
                                                    ->
                                                    outputStream().use { input.copyTo(it) }
                                                }
                                            }
                                    }
                                val uri =
                                    androidx.core.content.FileProvider.getUriForFile(
                                        context,
                                        "${context.packageName}.files",
                                        out,
                                    )
                                context.startActivity(
                                    Intent.createChooser(
                                        Intent(Intent.ACTION_SEND)
                                            .setType("application/gzip")
                                            .putExtra(Intent.EXTRA_STREAM, uri)
                                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                                        "云盘组件源代码",
                                    )
                                )
                            }
                        }
                    }
                }
                "帮助" -> {
                    SettingsSection("照片流") {
                        HelpText("双指展开或收拢调整密度，松手后吸附。密集总览中点按照片，可展开附近的照片。长按进入多选，拖动可连续选择。")
                    }
                    SettingsSection("查看照片") {
                        HelpText("双指或双击缩放，放大后拖动查看。原始倍率下左右滑动切换，轻点收放工具栏；横屏自动全屏。")
                    }
                    SettingsSection("云端资源") {
                        HelpText("整理资源库时可以离开页面，返回后查看进度。照片打开时下载原图，视频按播放需要传输；没有网络时仍可查看已缓存的内容。")
                    }
                }
                "隐私" -> privacy.split("\n\n").forEach { paragraph ->
                    Text(paragraph.trimStart('#', ' ').replace("`", ""),
                        fontSize = if(paragraph.startsWith('#')) 15.sp else 13.sp,
                        fontWeight = if(paragraph.startsWith('#')) FontWeight.SemiBold else FontWeight.Normal,
                        color = if(paragraph.startsWith('#')) c.text else c.secondary,
                        lineHeight = 21.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 7.dp))
                }
                "开源许可" -> Text(license, fontSize = 12.sp, color = c.secondary, lineHeight = 19.sp)
            }
            Spacer(Modifier.height(24.dp))
        }
    }
    if (cacheDialog)
        FilmDialog(
            onDismissRequest = { cacheDialog = false },
            title = { Text("清除缓存", fontWeight = FontWeight.Bold) },
            text = {
                Column {
                    SettingsToggle("预览图", preview) { preview = it }
                    SettingsToggle("已下载原图", original) { original = it }
                    Text("资源库索引、收藏和影集会保留。", fontSize = 12.sp, color = c.secondary)
                }
            },
            confirmButton = {
                FilmTextButton(
                    onClick = {
                        coroutine.launch {
                            try {
                                graph.clearCache(original, preview)
                                size = graph.cacheSize()
                                result = "已清除"
                            } catch (_: Exception) {
                                result = "请等待下载完成"
                            }
                            cacheDialog = false
                        }
                    }
                ) {
                    Text("清除")
                }
            },
            dismissButton = { FilmTextButton(onClick = { cacheDialog = false }) { Text("取消") } },
        )
    removing?.let { account ->
        FilmDialog(
            onDismissRequest = { removing = null },
            title = { Text("移除账号") },
            text = { Text("同时移除该账号的资源库，原文件不受影响。", fontSize = 14.sp) },
            confirmButton = {
                FilmTextButton(
                    onClick = {
                        s.libraries
                            .filter { it.account == account.id }
                            .forEach { graph.removeLibrary(it.id) }
                        coroutine.launch(Dispatchers.IO) { graph.cloud.disconnect(account.id) }
                        accounts = accounts.filterNot { it.id == account.id }
                        removing = null
                    }
                ) {
                    Text("移除")
                }
            },
            dismissButton = { FilmTextButton(onClick = { removing = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    val c = LocalFilm.current
    Text(
        title,
        Modifier.padding(start = 4.dp, top = 12.dp, bottom = 10.dp),
        fontSize = 12.sp,
        color = c.secondary,
    )
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(c.panel),
        content = content,
    )
    Spacer(Modifier.height(12.dp))
}

@Composable
private fun SettingsLink(
    label: String,
    icon: ImageVector,
    value: String = "",
    onClick: () -> Unit,
) {
    val c = LocalFilm.current
    FilmListItem(
        headlineContent = { Text(label, fontSize = 14.sp) },
        leadingContent = { Icon(icon, null, Modifier.size(20.dp)) },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (value.isNotEmpty()) Text(value, fontSize = 12.sp, color = c.secondary)
                Icon(Icons.Outlined.ChevronRight, null, Modifier.size(20.dp))
            }
        },
        modifier = Modifier.clickable(onClick = onClick),
    )
}

@Composable
private fun SettingsValue(label: String, value: String) {
    val c = LocalFilm.current
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, fontSize = 14.sp)
        Text(value, fontSize = 13.sp, color = c.secondary)
    }
}

@Composable
private fun SettingsToggle(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .toggleable(value, role = Role.Switch, onValueChange = onChange)
            .padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, Modifier.weight(1f), fontSize = 14.sp)
        FilmSwitch(value, null)
    }
}

@Composable
private fun HelpText(text: String) {
    Text(
        text,
        Modifier.padding(16.dp),
        fontSize = 14.sp,
        lineHeight = 24.sp,
        color = LocalFilm.current.secondary,
    )
}
