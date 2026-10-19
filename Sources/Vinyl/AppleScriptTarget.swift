import AppKit

enum ScriptError: Error { case notAuthorized, pending, notRunning, failed }

/// Runs AppleScript against one app, handling the Automation consent prompt.
@MainActor
final class AppleScriptTarget {
    let bundleID: String
    /// Called after the user answers the Automation prompt.
    var onPermissionResolved: (() -> Void)?

    private var compiled: [String: NSAppleScript] = [:]
    private var authorized = false
    private var askingForPermission = false

    init(bundleID: String) { self.bundleID = bundleID }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    nonisolated private static func automationStatus(_ bundleID: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
    }

    /// The first Apple Event to an app triggers the system consent prompt and blocks
    /// the sender until it's answered, so ask on a background thread and only script
    /// the app from the main thread once access is granted.
    private func checkPermission() throws {
        if authorized { return }
        switch Self.automationStatus(bundleID, ask: false) {
        case noErr:
            authorized = true
        case OSStatus(errAEEventNotPermitted):
            throw ScriptError.notAuthorized
        case OSStatus(errAEEventWouldRequireUserConsent):
            if !askingForPermission {
                askingForPermission = true
                let bundleID = bundleID
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = Self.automationStatus(bundleID, ask: true)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.askingForPermission = false
                            self.onPermissionResolved?()
                        }
                    }
                }
            }
            throw ScriptError.pending
        default:
            throw ScriptError.notRunning
        }
    }

    func run(_ body: String) throws -> NSAppleEventDescriptor {
        try checkPermission()
        let script: NSAppleScript
        if let cached = compiled[body] {
            script = cached
        } else {
            let text = "with timeout of 3 seconds\ntell application id \"\(bundleID)\"\n\(body)\nend tell\nend timeout"
            guard let made = NSAppleScript(source: text) else { throw ScriptError.failed }
            compiled[body] = made
            script = made
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            switch code {
            case -1743, -1744:
                authorized = false
                throw ScriptError.notAuthorized
            case -600, -609: throw ScriptError.notRunning
            default: throw ScriptError.failed
            }
        }
        return result
    }
}
