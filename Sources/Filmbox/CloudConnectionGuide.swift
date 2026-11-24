import SwiftUI
import FilmboxCore

struct CloudConnectionGuide: View {
    let provider: CloudProvider
    let reconnecting: Bool
    @Environment(\.colorScheme) private var scheme
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if provider == .baidu {
                Text("百度默认授权和令牌刷新经过 api.oplist.org，会向该服务发送刷新令牌。登录信息保存在本机，可在“关于菲林盒”查看隐私说明。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                step(1, title: "打开授权页面",
                     detail: "点击下方“登录百度网盘”，在打开的页面向下滚动，点击“获取 Token”。")
                step(2, title: "登录并授权",
                     detail: "在百度页面登录账号，按提示点击“登录并授权”。完成后会自动返回菲林盒。")
            } else {
                step(1, title: "登录夸克账号",
                     detail: "点击下方“登录夸克网盘”，使用夸克 App 扫码，或选择“手机登录”。")
                step(2, title: "返回菲林盒",
                     detail: "在网页中登录成功后，点击窗口右下角“完成登录”。")
            }
            if reconnecting {
                Text("登录成功后，原有资源库会自动恢复，无需重新选择文件夹。")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
            } else {
                step(3, title: "选择资源库文件夹",
                     detail: "打开要浏览的文件夹，再点击“添加此文件夹”。")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        CloudConnectionStep(number: number, title: title, detail: detail)
    }
}

struct CloudManualConnectionGuide: View {
    let provider: CloudProvider
    let reconnecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if provider == .baidu {
                CloudConnectionStep(number: 1, title: "在浏览器中授权", detail:
                    "打开下方授权页面，保留“使用 OpenList 提供的参数”，点击“获取 Token”，再登录百度账号并授权。")
                Link("打开百度授权页面 ↗", destination: CloudBaiduCallback.loginURL)
                    .font(.system(size: 12)).padding(.leading, 34)
                CloudConnectionStep(number: 2, title: "复制刷新令牌", detail:
                    "授权完成后，回到授权页面，复制“刷新令牌（Refresh Token）”的完整内容。")
                CloudConnectionStep(number: 3, title: "粘贴并连接", detail:
                    "把复制的内容粘贴到下方“刷新令牌”，点击右下角“连接”。" + completion)
            } else {
                CloudConnectionStep(number: 1, title: "在 Chrome 中登录夸克网盘", detail:
                    "打开下方夸克网盘网页，登录后进入“全部文件”。")
                Link("打开夸克网盘 ↗", destination: URL(string: "https://pan.quark.cn")!)
                    .font(.system(size: 12)).padding(.leading, 34)
                CloudConnectionStep(number: 2, title: "找到文件列表请求", detail:
                    "按 ⌥⌘I 打开开发者工具，选择 Network（网络），再按 ⌘R 刷新网页。点击域名为 drive.quark.cn 的 file/sort 请求。")
                CloudConnectionStep(number: 3, title: "复制完整 Cookie", detail:
                    "在 Headers（标头）的 Request Headers（请求标头）中找到 Cookie，复制它右侧的完整值，不包含“Cookie:”字样。")
                CloudConnectionStep(number: 4, title: "粘贴并连接", detail:
                    "回到菲林盒，粘贴到下方“Cookie”，点击右下角“连接”。" + completion)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var completion: String {
        reconnecting ? "连接成功后，原有资源库会自动恢复。" : "连接成功后，打开目标文件夹并点击“添加此文件夹”。"
    }
}

struct CloudWebDAVConnectionGuide: View {
    let reconnecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("如何连接").font(.system(size: 13, weight: .medium))
            CloudConnectionStep(number: 1, title: "获取 WebDAV 地址", detail:
                "在网盘或 NAS 的设置中启用 WebDAV，复制服务提供的完整地址（含端口和路径），粘贴到上方“WebDAV 地址”。普通文件分享链接不能用于连接。")
            CloudConnectionStep(number: 2, title: "填写账号", detail:
                "填写该服务的用户名和密码；如果服务提供专用的应用密码或授权码，请在“密码”中填写它。")
            CloudConnectionStep(number: 3, title: reconnecting ? "连接并恢复" : "选择资源库文件夹", detail:
                reconnecting ? "点击右下角“连接”，成功后原有资源库会自动恢复。" : "点击右下角“连接”。连接成功后，打开目标文件夹，再点击“添加此文件夹”。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CloudConnectionStep: View {
    let number: Int
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary)
                .frame(width: 22, height: 22)
                .background(palette.quietFill, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.text)
                    .padding(.top, 3)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
