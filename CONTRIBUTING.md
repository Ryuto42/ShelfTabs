# Contributing

Thanks for your interest in ShelfTabs. Issues and pull requests are welcome in English or Japanese.

## Getting started

1. Install Xcode 26 or later.
2. Clone the repository and run `swift build`.
3. Grant Accessibility permission on first launch. macOS may also ask for Input Monitoring.

An app started with `swift run` uses the Accessibility permission of the terminal that launched it, so allow your terminal in System Settings if needed.

To test it as an app bundle, use `scripts/package.sh`:

```sh
SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" NO_INSTALL=1 scripts/package.sh
```

Without `NO_INSTALL=1`, the script replaces and launches `/Applications/ShelfTabs.app`. `SIGN_IDENTITY=-` (ad hoc) resets the Accessibility permission on every build, so an Apple Development certificate is recommended.

## Project layout

| Folder | Contents |
|---|---|
| `Sources/ShelfTabs/Core` | Shelves, window control (Accessibility and SkyLight), input monitoring, native tabs, external dock |
| `Sources/ShelfTabs/UI` | Tab button, tab list popup, drop highlight, settings |
| `Sources/ShelfTabs/Settings` | Setting keys and defaults |
| `Resources/*.lproj` | Translations. Japanese strings are the keys, so add new UI text to `en.lproj/Localizable.strings` as well |

## Guidelines

- **Stay lightweight**: avoid constant polling and update from notifications or events.
- **Respect privacy**: if you add a network destination or read or store new data, update the Privacy section of the README.
- **Private APIs**: make sure the app still works when they are unavailable.
- **Never lose windows**: hidden windows must always come back on quit and after a crash.

## Pull requests

- Keep each pull request to one change.
- Attach a screenshot or video for UI changes.
- Make sure `swift build` succeeds without new warnings.
