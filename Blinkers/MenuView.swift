import KeyboardShortcuts
import SwiftUI

/// The popover. Standard controls only and no backgrounds of its own,
/// so it picks up Liquid Glass on macOS 26 and the classic look on 14 and 15.
struct MenuView: View {
    let controller: FocusController

    @AppStorage(Settings.Key.centerWindow) private var centerWindow = Settings.Default.centerWindow
    @AppStorage(Settings.Key.widthMode) private var widthMode = Settings.Default.widthMode
    @AppStorage(Settings.Key.pixelsWidth) private var pixelsWidth = Settings.Default.pixelsWidth
    @AppStorage(Settings.Key.windowPercent) private var windowPercent = Settings.Default.windowPercent
    @AppStorage(Settings.Key.sidesPercent) private var sidesPercent = Settings.Default.sidesPercent
    @AppStorage(Settings.Key.colorHex) private var colorHex = Settings.Default.colorHex
    @AppStorage(Settings.Key.opacity) private var opacity = Settings.Default.opacity

    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .toggleFocus)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.isTrusted {
                if controller.shortcutConflict {
                    conflictSection
                    Divider()
                }
                focusSection
                Divider()
                widthSection
                Divider()
                colorSection
                Divider()
                shortcutSection
            } else {
                accessibilitySection
            }
            Divider()
            Button("Quit Blinkers") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: centerWindow) { controller.settingsChanged() }
        .onChange(of: widthMode) { controller.settingsChanged() }
        .onChange(of: pixelsWidth) { controller.settingsChanged() }
        .onChange(of: windowPercent) { controller.settingsChanged() }
        .onChange(of: sidesPercent) { controller.settingsChanged() }
        .onChange(of: colorHex) { controller.settingsChanged() }
        .onChange(of: opacity) { controller.settingsChanged() }
    }

    // MARK: Sections

    private var accessibilitySection: some View {
        HStack {
            Text("Grant Accessibility access")
                .fixedSize()
            Spacer(minLength: 12)
            Button("Set Up…") { Onboarding.shared.show(controller: controller) }
        }
    }

    private var conflictSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Another app probably also uses this shortcut. Record a new one below.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                controller.dismissShortcutConflict()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
    }

    private var focusSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Focus").font(.headline)
                if let shortcut {
                    Text(shortcut.description).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Focus", isOn: Binding(get: { controller.isActive }, set: { controller.setFocus($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var widthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Center window", isOn: $centerWindow)
            widthControls
                .disabled(!centerWindow)
        }
    }

    private var widthControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Width")
                Spacer()
                Picker("Width", selection: $widthMode) {
                    ForEach(WidthMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            switch widthMode {
            case .pixels:
                HStack {
                    Spacer()
                    TextField("Width", value: $pixelsWidth, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .labelsHidden()
                        .onSubmit { pixelsWidth = max(pixelsWidth.rounded(), Settings.pixelsMin) }
                    Stepper("Width", value: $pixelsWidth, in: Settings.pixelsMin...100_000, step: Settings.pixelsStep)
                        .labelsHidden()
                    Text("px").foregroundStyle(.secondary)
                }
            case .window:
                percentSlider(value: $windowPercent, in: Settings.windowRange)
            case .sides:
                percentSlider(value: $sidesPercent, in: Settings.sidesRange)
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
            HStack {
                Text("Opacity")
                percentSlider(value: $opacity, in: 0...100)
            }
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shortcut")
                Spacer()
                KeyboardShortcuts.Recorder(for: .toggleFocus) {
                    shortcut = $0
                    controller.dismissShortcutConflict()
                }
            }
            LaunchAtLoginToggle()
        }
    }

    // MARK: Helpers

    private func percentSlider(value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Slider(value: value, in: range, step: Settings.percentStep)
            Text("\(Int(value.wrappedValue)) %")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: colorHex) ?? .black) },
            set: { colorHex = NSColor($0).hexString }
        )
    }
}
