import app_links
import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    if let url = connectionOptions.urlContexts.first?.url {
      AppLinks.shared.handleLink(url: url)
    } else if let userActivity = connectionOptions.userActivities.first,
              let url = userActivity.webpageURL {
      AppLinks.shared.handleLink(url: url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts {
      AppLinks.shared.handleLink(url: context.url)
    }
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    super.scene(scene, continue: userActivity)
    if let url = userActivity.webpageURL {
      AppLinks.shared.handleLink(url: url)
    }
  }
}