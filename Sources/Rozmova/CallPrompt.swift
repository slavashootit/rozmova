import AppKit
import QuartzCore
import SwiftUI

/// Floating card in the top-right corner: "Call in Zoom — record?". A non-activating panel, so
/// it shows over everything (full-screen calls included) without taking focus from the call.
@MainActor
final class CallPrompt {
    var onRecord: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// "Never ask for this app": dictation tools and other non-call mic users.
    var onNeverAsk: (() -> Void)?

    /// Hide by itself if nobody answers; the menu still has "Почати запис".
    private let timeout: TimeInterval = 60
    private let model = CallPromptModel()
    private var panel: PromptPanel?
    private var hideTimer: Timer?
    /// Bumped on every show, so a fade-out that finishes late doesn't hide the new prompt.
    private var generation = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    init() {
        model.onRecord = { [weak self] in
            self?.hide()
            self?.onRecord?()
        }
        model.onDismiss = { [weak self] in
            self?.hide()
            self?.onDismiss?()
        }
        model.onNeverAsk = { [weak self] in
            self?.hide()
            self?.onNeverAsk?()
        }
    }

    func show(call: CallApp, title: String?) {
        model.appName = call.name
        model.title = title
        model.icon = Self.icon(for: call)
        model.recordScreen = Prefs.recordScreen
        model.known = call.known

        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh view each time, so the size below fits this call's title.
        let content = NSHostingView(rootView: CallPromptView(model: model))
        panel.contentView = content
        let size = content.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = NSRect(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12,
                           width: size.width, height: size.height)

        // Slide in from the right.
        panel.setFrame(frame.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        panel.invalidateShadow()
        NSSound(named: "Tink")?.play()

        hideTimer?.invalidate()
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let panel, panel.isVisible else { return }
        let shown = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.generation == shown {
                    panel.orderOut(nil)
                    // Drop the view: its phase animator keeps redrawing an ordered-out panel.
                    panel.contentView = nil
                }
            }
        })
    }

    private func makePanel() -> PromptPanel {
        let panel = PromptPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        return panel
    }

    /// The app's own icon; helper processes (Chrome Helper) resolve to their browser.
    private static func icon(for call: CallApp) -> NSImage? {
        let prefix = call.bundleID.lowercased()
        let apps = NSWorkspace.shared.runningApplications
            .filter { ($0.bundleIdentifier ?? "").lowercased().hasPrefix(prefix) }
        return (apps.first { $0.activationPolicy == .regular } ?? apps.first)?.icon
    }
}

/// Clicks on the buttons need a panel that can become key; `.nonactivatingPanel` keeps the
/// call app frontmost anyway.
private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CallPromptModel: ObservableObject {
    @Published var appName = ""
    @Published var title: String?
    @Published var icon: NSImage?
    @Published var recordScreen = Prefs.recordScreen {
        didSet { Prefs.recordScreen = recordScreen }
    }
    /// A known call app; for anything else the card offers "never ask for this app".
    @Published var known = true
    var onRecord: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onNeverAsk: () -> Void = {}
}

struct CallPromptView: View {
    @ObservedObject var model: CallPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                appIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text("Дзвінок у \(model.appName)")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.title ?? "Записати цю розмову?")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: model.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Закрити")
            }

            HStack(spacing: 8) {
                Button(action: model.onRecord) {
                    HStack(spacing: 6) {
                        // Phase animation stays on the dot; a repeating withAnimation would
                        // also animate the card's layout and make everything wobble.
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                            .phaseAnimator([1.0, 0.35]) { dot, opacity in
                                dot.opacity(opacity)
                            } animation: { _ in
                                .easeInOut(duration: 0.9)
                            }
                        Text("Записати")
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)

                Button("Не зараз", action: model.onDismiss)
                    .buttonStyle(PillButtonStyle(prominent: false))
            }

            HStack {
                Toggle("Разом із записом екрана", isOn: $model.recordScreen)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                if !model.known {
                    Button("Це не дзвінок", action: model.onNeverAsk)
                        .buttonStyle(.plain)
                        .underline()
                        .help("Більше не питати для \(model.appName)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = model.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 40, height: 40)
        } else {
            Image(systemName: "phone.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green))
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Capsule().fill(prominent ? Color.red : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
