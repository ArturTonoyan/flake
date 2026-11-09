import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var overlay: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController()
        overlay?.start()

        statusBar = StatusBarController(overlay: overlay!)
        statusBar?.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stop()
    }
}
