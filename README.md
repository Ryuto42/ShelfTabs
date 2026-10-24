# ShelfTabs

[日本語](README.ja.md)

A menu-bar app for macOS 26 and later that groups the windows of any app into a "shelf" and switches between them with tabs.

## Features

- **Tabs for any app**: drag a window onto the top-left corner of another window (a blue outline appears) to merge them. Holding the modifier key (Shift by default) lets you drop anywhere on the window.
- **Tab switching**: a small glass button appears above the traffic lights of a merged window. Hover over it to show the tab list, then rest the pointer on a row to switch to it.
- **Tab management**: drag a row out of the list to split it, drop it on another shelf's button to move it, or reorder rows with the ≡ handle. "Add Window" adds an open window. Right-click the button to rename the shelf, change its accent color, or dissolve it. Minimizing one window minimizes the whole shelf.
- **Keyboard**: Ctrl+Opt+[ / ] cycles through the tabs of the focused shelf (configurable).
- **Finder and Preview**: windows of these apps are combined into their native tabs, new windows can open as tabs of an existing window, and resting the pointer on a native tab switches to it.
- **Window snapping**: drag windows to screen edges and corners, or use keyboard shortcuts, to tile them. Areas and shortcuts are configurable.
- **External dock support**: reserves screen space for a third-party Dock app.
- **Adaptive appearance**: Liquid Glass or a solid color, following "Reduce transparency", "Increase contrast", and light/dark mode.
- **Automatic updates** with [Sparkle](https://sparkle-project.org). Updates are verified with an EdDSA signature before they are applied.

## Screenshots

_Coming soon._

## Install

Requires macOS 26 Tahoe or later (Apple silicon and Intel).

1. Download `ShelfTabs-x.y.z.zip` from [Releases](https://github.com/Ryuto42/ShelfTabs/releases), unzip it, and move `ShelfTabs.app` to `/Applications`.
2. If the release is not notarized, macOS blocks the first launch. Open `ShelfTabs.app` once, then go to System Settings > Privacy & Security and click "Open Anyway". Alternatively, run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/ShelfTabs.app
   ```

3. Grant the permissions below when asked.

Homebrew is not available yet.

## Permissions

- **Accessibility** (required): reads and moves windows, and is needed to receive keyboard and mouse events. Grant it in System Settings > Privacy & Security > Accessibility.
- **Input Monitoring**: macOS may ask for it so ShelfTabs can watch for shortcuts and drags.

Builds signed with a different identity are treated as a different app by macOS, so you may need to grant Accessibility again after an update that changes the signature.

## Privacy

ShelfTabs has no analytics and sends nothing about you. The only network access is the Sparkle update check, which fetches `appcast.xml` and update archives from GitHub. What it reads on your Mac:

- **Windows**: titles, positions, sizes, and window IDs of other apps through the Accessibility API, to build tab bars and move windows. Nothing is stored except the parked-window journal described below.
- **Keys and mouse**: key codes are only matched against your configured shortcuts; they are never stored or sent. Other input is passed through untouched.
- **Finder and Preview**: ShelfTabs presses menu items in these two apps to merge or split native tabs.
- **External dock app** (optional): reads that app's `reservedAreas` preference to learn how much space it needs.
- **Wallpaper**: the desktop image is loaded for the preview in the snap settings only.
- **Settings**: stored in UserDefaults (`com.ryuto.shelftabs`), including shortcuts, appearance, and the remembered external dock edge.
- **Private APIs**: SkyLight (`SLSSetWindowAlpha` and related) and `_AXUIElementGetWindow`. They may stop working after a macOS update, and the app cannot be distributed on the Mac App Store.

## Recovery after a crash

Windows hidden behind tabs are recorded in `~/Library/Application Support/ShelfTabs/parked.json`. If ShelfTabs quits unexpectedly, parked windows are moved back on screen the next time it launches (with Accessibility permission). You can also choose "Restore All Windows" from the menu-bar icon at any time. Shelves themselves are not restored after a restart.

## Build from source

Requires Xcode 26 or later.

```sh
git clone https://github.com/Ryuto42/ShelfTabs.git
cd ShelfTabs
swift build
```

To build an app bundle, sign it, install it to `/Applications`, and launch it:

```sh
security find-identity -v -p codesigning
SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" scripts/package.sh
```

Use `NO_INSTALL=1` to write `dist/ShelfTabs.app` without installing. `SIGN_IDENTITY=-` signs ad hoc, which resets the Accessibility permission on every build. Local builds without `Resources/sparkle-public-key.txt` have automatic updates disabled.

### Releasing (maintainers)

```sh
scripts/setup-sparkle-keys.sh   # once: creates the signing key and saves the public key
SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=... scripts/release.sh 0.1.0
```

This writes a universal zip and a signed `appcast.xml` to `dist/` and prints the `gh release create` command. Without a Developer ID, an Apple Development certificate also works (omit `NOTARY_PROFILE`); the build is then not notarized. Always sign releases with the same certificate so users keep their Accessibility permission across updates. Back up the private key with `generate_keys -x`.

## Uninstall

Quit ShelfTabs, delete `/Applications/ShelfTabs.app`, and optionally remove `~/Library/Application Support/ShelfTabs` and its preferences with `defaults delete com.ryuto.shelftabs`. Turn off "Launch at login" in the settings first if you enabled it.

## License

[MIT](LICENSE)

## Credits

Parts of the implementation are adapted from Origami (MIT, by XiaoXianThis). Updates use [Sparkle](https://sparkle-project.org) (MIT). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
