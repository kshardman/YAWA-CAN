import UIKit

enum SharePresenter {
    @MainActor
    static func present(items: [Any]) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            AppLogger.log("[N1] share presenter failed: no foreground window scene")
            return
        }

        guard let root = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windowScene.windows.first?.rootViewController
        else {
            AppLogger.log("[N1] share presenter failed: no root view controller")
            return
        }

        let presenter = topViewController(from: root)
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)

        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }

        AppLogger.log("[N1] share presenter presenting from=\(String(describing: type(of: presenter)))")
        presenter.present(activity, animated: true)
    }

    @MainActor
    private static func topViewController(from root: UIViewController) -> UIViewController {
        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        if let nav = current as? UINavigationController {
            return nav.visibleViewController ?? nav
        }
        if let tab = current as? UITabBarController {
            return tab.selectedViewController ?? tab
        }
        return current
    }
}
