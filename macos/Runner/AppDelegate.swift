import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private let fileOpenChannelName = "md_desktop/file_open"
  private var fileOpenChannel: FlutterMethodChannel?
  private var pendingFilePaths: [String] = []

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      fileOpenChannel = FlutterMethodChannel(
        name: fileOpenChannelName,
        binaryMessenger: controller.engine.binaryMessenger)

      fileOpenChannel?.setMethodCallHandler { [weak self] call, result in
        guard call.method == "consumePendingFilePaths" else {
          result(FlutterMethodNotImplemented)
          return
        }

        let paths = self?.pendingFilePaths ?? []
        self?.pendingFilePaths.removeAll()
        result(paths)
      }
    }

    super.applicationDidFinishLaunching(notification)
  }

  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    publishFilePaths([filename])
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    publishFilePaths(urls.map { $0.path })
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func publishFilePaths(_ paths: [String]) {
    guard !paths.isEmpty else {
      return
    }

    if let channel = fileOpenChannel {
      channel.invokeMethod("openFiles", arguments: paths)
    } else {
      pendingFilePaths.append(contentsOf: paths)
    }
  }
}
