import Combine
import Foundation

@MainActor
final class PlatformAccountService: ObservableObject {
    @Published private(set) var accounts: [ComicPlatform: PlatformAccount]
    @Published private(set) var isJmAutoLoginRunning = false
    @Published private(set) var lastJmAutoLoginAt: Date?
    @Published private(set) var lastJmAutoLoginError: String?

    init(defaults: UserDefaults = .standard) {
        accounts = PicaXSQLiteStore.loadPlatformAccounts(defaults: defaults)
    }

    var loggedInAccounts: [PlatformAccount] {
        ComicPlatform.onlinePlatforms.compactMap { accounts[$0] }
    }

    func account(for platform: ComicPlatform) -> PlatformAccount? {
        accounts[platform]
    }

    func isLoggedIn(_ platform: ComicPlatform) -> Bool {
        accounts[platform] != nil
    }

    func saveValidatedAccount(_ account: PlatformAccount) throws {
        try PicaXSQLiteStore.upsertPlatformAccountOrThrow(account)
        accounts[account.platform] = account
    }

    func logout(platform: ComicPlatform) throws {
        try PicaXSQLiteStore.deletePlatformAccountOrThrow(platform: platform)
        accounts[platform] = nil
    }

    func reloadFromDefaults() {
        accounts = PicaXSQLiteStore.loadPlatformAccounts()
    }

    /// Attempts a fresh JMComic sign-in with the locally saved password. The
    /// attempt is throttled so app launch and `scenePhase` changes do not issue
    /// duplicate logins back to back.
    func autoLoginJmComicIfNeeded(minimumInterval: TimeInterval = 300) async {
        guard PlatformFeatureSettings.jmAutoLogin() else {
            return
        }
        guard let account = accounts[.jmComic], account.hasReusableCredential else {
            return
        }
        guard !isJmAutoLoginRunning else {
            return
        }
        if let lastJmAutoLoginAt,
           Date().timeIntervalSince(lastJmAutoLoginAt) < minimumInterval {
            return
        }

        isJmAutoLoginRunning = true
        lastJmAutoLoginAt = Date()
        defer { isJmAutoLoginRunning = false }

        do {
            let refreshedAccount = try await ComicContentService().refreshJmSession(account: account)
            accounts[refreshedAccount.platform] = refreshedAccount
            lastJmAutoLoginError = nil
        } catch where error.isTaskCancellation {
            return
        } catch {
            lastJmAutoLoginError = error.localizedDescription
        }
    }
}

enum PlatformAccountError: LocalizedError, Equatable {
    case emptyUsername
    case emptyPassword
    case emptyCredential

    var errorDescription: String? {
        switch self {
        case .emptyUsername:
            "请输入账号"
        case .emptyPassword:
            "请输入密码"
        case .emptyCredential:
            "登录成功后没有取得可保存的登录信息"
        }
    }
}
