import AppKit
import SwiftUI

/// Opens sheets (alerts, confirmations, logs, Checkup) in the middle of the window instead of
/// dropping them from the title bar. Sits in front of SwiftUI's window delegate and forwards
/// everything else to it.
final class SheetCentering: NSObject, NSWindowDelegate {
    private weak var inner: NSWindowDelegate?
    /// The window holds its delegate weakly; keep each proxy alive as long as its window.
    private static var proxies: [ObjectIdentifier: SheetCentering] = [:]

    @MainActor static func install(on window: NSWindow) {
        guard !(window.delegate is SheetCentering) else { return }
        let proxy = SheetCentering()
        proxy.inner = window.delegate
        proxies[ObjectIdentifier(window)] = proxy
        window.delegate = proxy
    }

    private var resizeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        // SwiftUI sizes the sheet after this call, so centre it again whenever it resizes.
        let id = ObjectIdentifier(sheet)
        if resizeObservers[id] == nil {
            resizeObservers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: sheet, queue: .main) { [weak window, weak sheet] _ in
                MainActor.assumeIsolated {
                    guard let window, let sheet, sheet.sheetParent === window else { return }
                    let f = window.frame
                    let y = (f.midY - sheet.frame.height / 2).rounded()
                    let x = (f.midX - sheet.frame.width / 2).rounded()
                    // Never above where macOS would attach it (just under the title bar).
                    let maxY = rect.origin.y + f.minY - sheet.frame.height
                    sheet.setFrameOrigin(NSPoint(x: x, y: min(y, maxY)))
                }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: sheet, queue: .main) { [weak self] _ in
                if let o = self?.resizeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(o) }
            }
        }
        // `rect.origin.y` is where the sheet's top edge would attach; never go above it.
        let top = min(rect.origin.y, ((window.frame.height + sheet.frame.height) / 2).rounded())
        return NSRect(x: 0, y: top, width: window.frame.width, height: 0)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        inner?.responds(to: selector) == true ? inner : nil
    }
}

/// Installs `SheetCentering` on the window this view lands in.
struct CenteredSheets: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { SheetCentering.install(on: w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { SheetCentering.install(on: w) } }
    }
}

@MainActor
enum Dialogs {
    /// The window an AppKit alert should attach to: the frontmost sheet of the main window,
    /// or nil when Bubble has no window open (menu bar only).
    static var host: NSWindow? {
        guard var w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return nil }
        while let s = w.attachedSheet { w = s }
        return w
    }

    /// Runs `alert` modally as a sheet on Bubble's window (so it opens centred, like every other
    /// dialog), or as a free-standing alert when there's no window.
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard let host else { return alert.runModal() }
        alert.beginSheetModal(for: host) { code in
            if NSApp.modalWindow == alert.window { NSApp.stopModal(withCode: code) }
        }
        let response = NSApp.runModal(for: alert.window)
        // Stopped from outside (a timeout): take the sheet down too.
        if alert.window.isVisible { host.endSheet(alert.window, returnCode: response) }
        return response
    }
}
