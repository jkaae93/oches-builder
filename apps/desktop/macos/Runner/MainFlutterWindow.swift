import Cocoa
import FlutterMacOS

@objc protocol CoreReadinessProtocol {
  func readiness(withReply reply: @escaping (String) -> Void)
}

class MainFlutterWindow: NSWindow {
  private var coreChannel: FlutterMethodChannel?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "com.oches.core/readiness",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    coreChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "readiness" else {
        result(FlutterMethodNotImplemented)
        return
      }
      Self.probeCore(result: result)
    }

    super.awakeFromNib()
  }

  private static func probeCore(result: @escaping FlutterResult) {
    func valid(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte)
          || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
      }
    }
    guard #available(macOS 14.0, *),
      let service = Bundle.main.object(forInfoDictionaryKey: "OchesCoreServiceName") as? String,
      let team = Bundle.main.object(forInfoDictionaryKey: "OchesCoreTeamID") as? String,
      let identifier = Bundle.main.object(forInfoDictionaryKey: "OchesCoreSigningIdentifier") as? String,
      valid(service), valid(team), valid(identifier)
    else {
      result("unavailable")
      return
    }
    let connection = NSXPCConnection(serviceName: service)
    connection.remoteObjectInterface = NSXPCInterface(with: CoreReadinessProtocol.self)
    connection.setCodeSigningRequirement(
      "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    )
    var completed = false
    let finish = {
      DispatchQueue.main.async {
        guard !completed else { return }
        completed = true
        connection.invalidate()
        result("unavailable")
      }
    }
    connection.interruptionHandler = finish
    connection.invalidationHandler = finish
    connection.resume()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish() }) as? CoreReadinessProtocol else {
      finish()
      return
    }
    proxy.readiness { _ in finish() }
  }
}
