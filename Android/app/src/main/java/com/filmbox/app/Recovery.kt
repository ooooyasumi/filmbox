package com.filmbox.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

enum class RecoveryProblem(
    val code: String,
    val title: String,
    val detail: String,
    val action: String,
) {
    INCOMPLETE("incomplete", "原文件未完整读取", "收到的文件与索引大小不一致。请刷新资源库核对最新文件，并在网盘中确认原文件可正常打开。", "刷新资源库"),
    SECURE(
        "secure_connection_failed",
        "无法验证云盘连接",
        "请检查服务器证书、HTTPS 地址和设备时间。可在浏览器中打开云盘确认连接。",
        "打开网盘",
    ),
    LOGIN("authentication_expired", "需要重新登录", "登录已失效，重新登录后会继续加载。已缓存的内容仍可查看。", "重新登录"),
    NETWORK("network_unavailable", "网络未连接", "请检查网络连接。连接恢复后会自动检查未完成的资源库。", "网络设置"),
    TIMEOUT("network_timeout", "连接超时", "云盘未及时响应，已自动尝试恢复。请检查网络，或稍后刷新。", "网络设置"),
    SERVICE("provider_unavailable", "云盘暂时不可用", "云盘服务未能完成请求，已自动尝试恢复。可在网盘中确认服务状态，稍后刷新。", "打开网盘"),
    LIMITED("rate_limited", "云盘请求受限", "云盘限制了请求频率，已停止连续请求。请稍后刷新。", "打开网盘"),
    DENIED("access_denied", "云盘拒绝访问", "云盘已拒绝访问。请在网盘中检查文件权限或账户限制；重新登录未必能解决。", "打开网盘"),
    MISSING("not_found", "找不到文件或文件夹", "文件或文件夹可能已移动或删除。刷新资源库以核对当前位置。", "刷新资源库"),
    OFFLINE("storage_offline", "资源库未连接", "请连接存储设备。设备已连接时，可重新选择原文件夹恢复访问。", "重新连接"),
    PERMISSION("storage_permission", "需要访问权限", "系统未允许访问。请重新授权原文件夹或照片。", "重新授权"),
    STORAGE("storage_full", "存储空间不足", "请清理设备空间或应用缓存，再继续加载。", "打开设置"),
    ENGINE("engine_unavailable", "云盘连接组件不可用", "自动恢复连接未成功。请重新启动应用；仍有问题时重新安装最新版。", "复制诊断信息"),
    UNSUPPORTED("unsupported_media", "无法预览此文件", "文件可能损坏，或当前设备不支持此格式。可用其他应用打开以确认。", "用其他应用打开"),
    UNKNOWN("unknown", "未能完成加载", "暂时无法确认原因。可复制诊断信息，便于进一步排查。", "复制诊断信息");

    val automaticRetry
        get() = this in setOf(NETWORK, TIMEOUT, SERVICE, ENGINE)

    val accountWide
        get() = this in setOf(LOGIN, NETWORK, TIMEOUT, SERVICE, LIMITED, ENGINE, SECURE)

    companion object {
        fun code(code: String?): RecoveryProblem =
            when (code) {
                "auth_expired",
                "account_not_connected" -> LOGIN
                "provider_error" -> SERVICE
                else -> entries.firstOrNull { it.code == code } ?: UNKNOWN
            }

        @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
        fun from(error: Throwable?, cloud: Boolean): RecoveryProblem {
            if (error is CloudFailure) return code(error.reason)
            var cause = error
            repeat(8) {
                when (cause) {
                    is androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException -> {
                        val response =
                            cause
                                as
                                androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException
                        val code =
                            response.headerFields.entries
                                .firstOrNull { it.key.equals("X-Filmbox-Error", true) }
                                ?.value
                                ?.firstOrNull()
                        return if (code != null) RecoveryProblem.code(code)
                        else
                            when (response.responseCode) {
                                403 -> DENIED
                                404,
                                410 -> MISSING
                                429 -> LIMITED
                                else -> UNKNOWN
                            }
                    }
                    is SecurityException -> return PERMISSION
                    is android.database.sqlite.SQLiteFullException -> return STORAGE
                    is java.io.FileNotFoundException -> return MISSING
                    is javax.net.ssl.SSLException -> if (cloud) return SECURE
                    is java.net.SocketTimeoutException -> if (cloud) return TIMEOUT
                    is java.net.UnknownHostException,
                    is java.net.NoRouteToHostException -> if (cloud) return NETWORK
                }
                cause = cause?.cause
            }
            return if (cloud) UNKNOWN else UNSUPPORTED
        }
    }
}

data class RecoveryRequest(
    val problem: RecoveryProblem,
    val source: String,
    val media: Media? = null,
)

@Composable
fun RecoveryNotice(problem: RecoveryProblem, modifier: Modifier = Modifier, onAction: () -> Unit) {
    val c = LocalFilm.current
    Column(
        modifier
            .widthIn(max = 400.dp)
            .background(c.panel.copy(alpha = .96f), RoundedCornerShape(16.dp))
            .padding(16.dp)
    ) {
        Text(problem.title, fontSize = 13.sp)
        Text(
            problem.detail,
            Modifier.padding(top = 5.dp, bottom = 8.dp),
            fontSize = 12.sp,
            color = c.secondary,
        )
        FilmTextButton(onClick = onAction) { Text(problem.action) }
    }
}
