import UIKit

@main
final class SceneDelegate: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        window = UIWindow(windowScene: scene as! UIWindowScene)
        window!.rootViewController = ViewController()
        window!.makeKeyAndVisible()
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        ShelfVersionReceipt.recordCurrentBuild()
    }
}
