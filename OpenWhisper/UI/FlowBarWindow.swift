import AppKit
import SwiftUI

@MainActor
final class FlowBarController {
    private var panel: NSPanel?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Show the flow bar (always visible — call on startup)
    func show() {
        owLog("[FlowBar] show() called, panel exists: \(panel != nil)")
        if panel == nil {
            createPanel()
        }
        owLog("[FlowBar] panel frame: \(panel?.frame ?? .zero)")
        panel?.alphaValue = 0
        panel?.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel?.animator().alphaValue = 1
        }
    }

    func hide() {
        let panelRef = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef?.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panelRef?.orderOut(nil)
            }
        })
    }

    /// Show a brief "done" flash, then shrink back to idle pill
    func flashDone() {
        // Flow bar stays visible — it just animates back to idle state via SwiftUI
        // (recordingState goes back to .idle, FlowBarView reacts)
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar  // Above floating windows
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        // Position at bottom center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 160
            let y = screenFrame.minY + 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            owLog("[FlowBar] Positioned at (\(x), \(y)) on screen \(screenFrame)")
        }

        if let appState {
            let flowBarView = FlowBarView()
                .environment(appState)
                .fixedSize()
            let hostingView = NSHostingView(rootView: flowBarView)
            panel.contentView = hostingView
        }

        self.panel = panel
    }
}
