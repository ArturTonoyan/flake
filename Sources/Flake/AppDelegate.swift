import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var overlay: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController()
        overlay?.start()

        if let overlay {
            DuelArenaController.shared.configure(
                network: overlay.peerNetwork,
                peers: { overlay.lanPeers }
            )
        }

        statusBar = StatusBarController(overlay: overlay!)
        statusBar?.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stop()
    }
}
