import SwiftUI
import FilmboxCore

struct CloudConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let accounts: [CloudAccount]
    let reconnectAccount: CloudAccount?
    let initialAccount: CloudAccount?
    var onBack: (() -> Void)? = nil
    let onAdd: (CloudAccount, CloudLibraryReference, String) -> Void
    @State private var provider: CloudProvider
    @State private var credential = ""
    @State private var endpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showingLogin = false
    @State private var loginSession: CloudLoginSession?
    @State private var showingManual = false
    @State private var account: CloudAccount?
    @State private var activeAccountID: UUID?
    @State private var page: CloudDirectoryPage?
    @State private var ancestors: [(id: String, path: String, name: String)] = []
    @State private var currentID = "/"
    @State private var currentPath = "/"
    @State private var currentName = "全部文件"
    @State private var error: String?
    @State private var busy = false
    @State private var didAdd = false
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    private var palette: LightTablePalette { LightTablePalette(dark: scheme == .dark) }

    init(accounts: [CloudAccount] = [], reconnectAccount: CloudAccount? = nil, initialAccount: CloudAccount? = nil, onBack: (() -> Void)? = nil,
         onAdd: @escaping (CloudAccount, CloudLibraryReference, String) -> Void) {
        self.accounts = accounts
        self.reconnectAccount = reconnectAccount
        self.initialAccount = initialAccount
        self.onBack = onBack
        self.onAdd = onAdd
        _provider = State(initialValue: reconnectAccount?.provider ?? initialAccount?.provider ?? .quark)
        _account = State(initialValue: initialAccount)
        _activeAccountID = State(initialValue: reconnectAccount?.id ?? initialAccount?.id)
        _endpoint = State(initialValue: reconnectAccount?.endpoint?.absoluteString ?? initialAccount?.endpoint?.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if onBack != nil && !showingLogin {
                    ChromeIconButton(title: "返回", symbol: "chevron.left") { onBack?() }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(showingLogin ? "登录\(provider.displayName)" : (account == nil ? (reconnectAccount == nil ? "添加云盘" : "重新登录") : "选择文件夹"))
                        .font(.system(size: 21, weight: .semibold))
                    if let account { Text(account.name).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                ChromeIconButton(title: "关闭", symbol: "xmark") { cancelAndDismiss() }
            }.padding(24)
            if showingLogin, let loginSession {
                EmbeddedCloudLoginPanel(session: loginSession, onBack: endLogin) { value in
                    credential = value
                    endLogin()
                    connect()
                }
            } else {
                if account == nil { connectionForm } else { folderPicker }
            }
            Spacer(minLength: 0)
            if let error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                }.font(.callout).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if !showingLogin {
                Divider()
                HStack(spacing: 12) {
                    if busy { ProgressView().controlSize(.small) }
                    if account == nil, provider != .webdav, !credential.isEmpty {
                        Button("重新登录", action: beginLogin).buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).disabled(busy)
                    }
                    Spacer()
                    Button("取消") { cancelAndDismiss() }.keyboardShortcut(.cancelAction)
                    if let account {
                        Button("添加此文件夹") {
                            didAdd = true
                            onAdd(account, CloudLibraryReference(accountID: account.id, folderID: currentID, path: currentPath),
                                  currentPath == "/" ? account.name : currentName)
                            dismiss()
                        }.buttonStyle(.borderedProminent).disabled(busy || page == nil)
                            .keyboardShortcut(.defaultAction)
                    } else if provider == .webdav || !credential.isEmpty {
                        Button("连接") { connect() }.buttonStyle(.borderedProminent).disabled(busy)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("登录\(provider.displayName)", action: beginLogin)
                            .buttonStyle(.borderedProminent).disabled(busy)
                            .keyboardShortcut(.defaultAction)
                    }
                }.padding(20)
            }
        }
        .frame(width: showingLogin ? 1000 : 680,
               height: showingLogin ? 700 : (account != nil ? 570 : (reconnectAccount != nil ? 540 : 600)))
        .background(palette.panel)
        .onAppear {
            if initialAccount != nil, page == nil { resetFolderLocation(); loadFolder() }
        }
        .onDisappear {
            operation?.cancel()
            if !didAdd, reconnectAccount == nil, let id = activeAccountID,
               !accounts.contains(where: { $0.id == id }) {
                Task { try? await CloudGateway.shared.forget(accountID: id) }
            }
        }
    }

    private var connectionForm: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if reconnectAccount == nil {
                        HStack(spacing: 10) {
                            providerButton(.quark)
                            providerButton(.baidu)
                            providerButton(.webdav)
                        }
                    }
                    if accounts.contains(where: { $0.provider == provider }) && reconnectAccount == nil {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("已连接的账户").font(.caption).foregroundStyle(.secondary)
                            ForEach(accounts.filter { $0.provider == provider }) { item in
                                Button {
                                    account = item
                                    activeAccountID = item.id
                                    resetFolderLocation()
                                    loadFolder()
                                } label: {
                                    HStack {
                                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                                        Text(item.name)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(12).contentShape(Rectangle())
                                }.buttonStyle(.plain).background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    if provider == .webdav {
                        VStack(alignment: .leading, spacing: 15) {
                            field("WebDAV 地址") { TextField("https://服务器地址/路径/", text: $endpoint) }
                            field("用户名") { TextField("用户名", text: $username) }
                            field("密码") { SecureField("密码", text: $password) }
                        }
                        CloudWebDAVConnectionGuide(reconnecting: reconnectAccount != nil)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            CloudConnectionGuide(provider: provider, reconnecting: reconnectAccount != nil)
                            VStack(alignment: .leading, spacing: 18) {
                                Button {
                                    showingManual.toggle()
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: showingManual ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                                        Text("手动连接").font(.system(size: 12, weight: .medium))
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(palette.secondary)
                                    .padding(.horizontal, 12).frame(height: 40)
                                    .background(palette.quietFill, in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(showingManual ? "已展开" : "已折叠")
                                if showingManual {
                                    CloudManualConnectionGuide(provider: provider, reconnecting: reconnectAccount != nil)
                                    field(provider == .baidu ? "刷新令牌（Refresh Token）" : "Cookie") {
                                        SecureField(provider == .baidu ? "粘贴刷新令牌" : "粘贴完整 Cookie", text: $credential)
                                            .accessibilityLabel(provider == .baidu ? "百度网盘刷新令牌" : "夸克网盘登录 Cookie")
                                    }
                                }
                            }.id("manual-connection")
                        }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Reserve the largest native scrollbar gutter even when content fits.
                // Keep the leading edge and field widths identical for every provider
                // under both macOS overlay and always-visible scrollbar preferences.
                .id("connection-top")
                .frame(width: 616, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: showingManual) { _, expanded in
                if expanded {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo("manual-connection", anchor: .top)
                    }
                }
            }
            .onChange(of: provider) { _, _ in
                proxy.scrollTo("connection-top", anchor: .top)
            }
        }.disabled(busy)
    }

    private func providerButton(_ value: CloudProvider) -> some View {
        Button {
            provider = value
            activeAccountID = nil
            credential = ""
            error = nil
            showingManual = false
        } label: {
            VStack(spacing: 9) {
                Image(systemName: value.systemImage).font(.system(size: 23, weight: .light))
                Text(value.displayName).font(.system(size: 12, weight: .medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 18)
                .foregroundStyle(provider == value ? palette.accentText : palette.secondary)
                .background(provider == value ? palette.selectedFill : palette.raised, in: RoundedRectangle(cornerRadius: 15))
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).accessibilityAddTraits(provider == value ? .isSelected : [])
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.plain).padding(12)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var folderPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ChromeIconButton(title: "上一级文件夹", symbol: "chevron.left") {
                    guard let previous = ancestors.popLast() else { return }
                    currentID = previous.id; currentPath = previous.path; currentName = previous.name
                    loadFolder()
                }.disabled(ancestors.isEmpty || busy)
                Image(systemName: "folder").foregroundStyle(palette.accentText)
                Text(currentPath).lineLimit(1).truncationMode(.middle).font(.callout).textSelection(.enabled)
                Spacer()
                Button("重新登录") {
                    operation?.cancel()
                    operationID = UUID()
                    self.account = nil
                    page = nil
                    busy = false
                    error = nil
                    if provider != .webdav { beginLogin() }
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                ChromeIconButton(title: "刷新文件夹", symbol: "arrow.clockwise") { loadFolder() }.disabled(busy)
            }.padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) {
                    if let page, page.entries.isEmpty {
                        ContentUnavailableView("空文件夹", systemImage: "folder")
                            .frame(maxWidth: .infinity).padding(.vertical, 55)
                    }
                    ForEach(page?.entries ?? [], id: \.id) { entry in
                        Button {
                            guard entry.isDirectory else { return }
                            ancestors.append((currentID, currentPath, currentName))
                            currentID = entry.id
                            currentPath = currentPath == "/" ? "/\(entry.name)" : "\(currentPath)/\(entry.name)"
                            currentName = entry.name
                            loadFolder()
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(entry.isDirectory ? palette.accentText : palette.secondary)
                                    .frame(width: 22)
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if entry.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                            }.padding(.horizontal, 20).padding(.vertical, 11).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!entry.isDirectory || busy)
                    }
                }.padding(.vertical, 6)
            }.overlay { if busy && page == nil { ProgressView() } }
        }.background(palette.raised, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24).padding(.bottom, 16)
    }

    private func resetFolderLocation() {
        ancestors = []
        currentID = provider == .quark ? "0" : "/"
        currentPath = "/"
        currentName = "全部文件"
        page = nil
    }

    private func connect() {
        operation?.cancel()
        let id = UUID(); operationID = id
        busy = true; error = nil
        let connectionID = reconnectAccount?.id ?? activeAccountID ?? UUID()
        activeAccountID = connectionID
        operation = Task {
            do {
                let result = try await CloudGateway.shared.connect(provider: provider, credential: credential,
                    endpoint: provider == .webdav ? endpoint : nil, username: provider == .webdav ? username : nil,
                    password: provider == .webdav ? password : nil, accountID: connectionID)
                try Task.checkCancellation()
                guard operationID == id else { return }
                account = result
                activeAccountID = result.id
                credential = ""; password = ""
                if reconnectAccount != nil {
                    didAdd = true
                    onAdd(result, CloudLibraryReference(accountID: result.id, folderID: provider == .quark ? "0" : "/", path: "/"), result.name)
                    dismiss()
                    return
                }
                resetFolderLocation()
                let resultPage = try await CloudGateway.shared.list(account: result, folderID: currentID, path: currentPath)
                try Task.checkCancellation()
                guard operationID == id else { return }
                page = resultPage
            } catch is CancellationError {
            } catch {
                guard operationID == id else { return }
                self.error = error.localizedDescription
                if case CloudConnectionError.credentialsMissing = error { credential = "" }
            }
            if operationID == id { busy = false }
        }
    }

    private func loadFolder() {
        guard let account else { return }
        operation?.cancel()
        let id = UUID(); operationID = id
        busy = true; error = nil; page = nil
        let folderID = currentID; let path = currentPath
        operation = Task {
            do {
                let result = try await CloudGateway.shared.list(account: account, folderID: folderID, path: path)
                try Task.checkCancellation()
                guard operationID == id else { return }
                page = result
            } catch is CancellationError {
            } catch {
                guard operationID == id else { return }
                self.error = error.localizedDescription
            }
            if operationID == id { busy = false }
        }
    }

    private func beginLogin() {
        error = nil
        loginSession = CloudLoginSession(provider: provider)
        showingLogin = true
    }

    private func endLogin() {
        showingLogin = false
        loginSession?.stop()
        loginSession = nil
    }

    private func cancelAndDismiss() {
        operation?.cancel()
        operationID = UUID()
        endLogin()
        dismiss()
    }
}
