#if os(iOS)
import UIKit

final class PicaXAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AutoSuperResolutionBackgroundCoordinator.shared.register()
        return true
    }
}
#endif
