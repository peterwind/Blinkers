# Blinkers

A small macOS menu bar app that puts one window in the spotlight and dims everything else, so you can focus.

Press **⌃⌥B** and the front window gets a dark frame around it. Press it again, or click the dark area, and everything is back as it was.

## Features

- **Center window** (on by default): the window moves to the middle of the screen at a width you choose, and goes back to exactly where it was afterwards. With it off, the window stays put and the frame closes in around it.
- **Width** in three modes: a fixed width in points, a percentage of the screen, or how much of the screen the sides take up.
- **Color and opacity** of the frame, applied live.
- **Your own shortcut.** If another app moves the window on the same key press, Blinkers puts it back and tells you to pick a different shortcut.
- Follows the window when you move it, and steps aside when it's closed, minimized or goes full screen.
- Launch at login. No Dock icon, accounts or tracking.

## Requirements

- macOS 14 Sonoma or later
- Xcode 26 or later to build
- Accessibility permission, so Blinkers can move and resize windows. A short onboarding walks you through it on first launch.

## Building

1. Clone the repo and open `Blinkers.xcodeproj`.
2. Press ⌘R.

Out of the box the app is signed to run locally. macOS ties the Accessibility permission to the app's signature, and a local signature changes with every build, so you'd have to grant the permission again after each one. To avoid that, sign with your own team:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# then put your team ID in Config/Local.xcconfig
```

`Config/Local.xcconfig` is ignored by git. A free Apple ID in Xcode → Settings → Accounts is enough.

Run the tests with ⌘U.

## How it works

Blinkers moves windows through the Accessibility API and draws the frame as borderless panels of its own. Window moves through Accessibility can't be animated smoothly, so the frame does the moving: it closes over the window, the window jumps out of sight, and the frame opens again around its new place. All of that runs in Core Animation, with no extra permissions.

## License

MIT. See [LICENSE](LICENSE).
