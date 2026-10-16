import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Shows the welcome window: on first launch, and on later launches for as
/// long as Accessibility access is missing.
@MainActor
final class Onboarding {
    static let shared = Onboarding()
    private var window: NSWindow?

    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: Settings.Key.hasCompletedOnboarding) || !WindowMover.isTrusted
    }

    func show(controller: FocusController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = OnboardingView(controller: controller) { [weak self] in self?.finish() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Blinkers"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }

        window.makeKeyAndOrderFront(nil)
        // A menu bar app isn't active on launch; bring the window forward.
        NSApp.activate()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Settings.Key.hasCompletedOnboarding)
        window?.close()
    }
}

private struct OnboardingView: View {
    let controller: FocusController
    let onDone: () -> Void

    private enum Step { case welcome, access, ready }
    @State private var step = Step.welcome

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .access: access
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 40)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 480, height: 440)
        .onChange(of: controller.isTrusted) {
            // Move on by itself once access is granted in System Settings.
            if controller.isTrusted, step == .access {
                step = .ready
                NSApp.activate()
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Welcome to Blinkers")
                    .font(.title2.bold())
            }
            Text("Blinkers centers the window you're working in and dims everything around it, so only one thing has your attention.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                point("keyboard", "Press **\(shortcutText)** to focus the front window. Press it again, or click the dimmed area, to go back.")
                point("menubar.rectangle", "Width, color and the shortcut are in the Blinkers icon in the menu bar.")
                point("arrow.left.arrow.right", "Press the shortcut in another window to move focus there.")
            }
            .padding(.top, 6)
        }
    }

    private var access: some View {
        VStack(spacing: 18) {
            header(symbol: "hand.raised.fill", title: "Allow Blinkers to move windows")
            Text("macOS asks you to approve this once. Blinkers only uses it to move and resize the window you focus, and nothing leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if controller.isTrusted {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    numbered(1, "Click **Open System Settings** below.")
                    numbered(2, "Turn on **Blinkers** under Privacy & Security → Accessibility.")
                    numbered(3, "Come back here. This window continues by itself.")
                }
                .padding(.top, 6)
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 18) {
            header(symbol: "checkmark.circle.fill", title: "You're all set")
            Text("Click in the window you want to work in and press **\(shortcutText)**.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            LaunchAtLoginToggle()
                .padding(.top, 12)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch step {
            case .welcome:
                Spacer()
                Button("Continue") { step = controller.isTrusted ? .ready : .access }
                    .keyboardShortcut(.defaultAction)
            case .access:
                Button("Back") { step = .welcome }
                Spacer()
                if controller.isTrusted {
                    Button("Continue") { step = .ready }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") {
                        // Adds Blinkers to the list and shows the system prompt.
                        WindowMover.promptForTrust()
                        WindowMover.openAccessibilitySettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .ready:
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Helpers

    private var shortcutText: String {
        KeyboardShortcuts.getShortcut(for: .toggleFocus)?.description ?? "the shortcut"
    }

    private func header(symbol: String, title: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.bold())
        }
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func numbered(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit().bold())
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shared by the popover and onboarding so both reflect the real login item state.
struct LaunchAtLoginToggle: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: $isOn)
            .onChange(of: isOn) { update() }
    }

    private func update() {
        let service = SMAppService.mainApp
        do {
            if isOn {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            isOn = service.status == .enabled
        }
    }
}
