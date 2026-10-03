import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ControllerViewController()
        window?.makeKeyAndVisible()
        // Bailando no se toca la pantalla: que no se apague.
        application.isIdleTimerDisabled = true
        return true
    }
}
