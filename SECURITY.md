# Security Policy

## Reporting a vulnerability

Please do not open a public issue. Report vulnerabilities through GitHub's [private vulnerability reporting](https://github.com/Ryuto42/ShelfTabs/security/advisories/new). I will confirm the report and follow up until a fixed release is published.

## Supported versions

Only the latest release is supported.

## Areas of interest

- **Event tap**: keyboard and mouse monitoring with `CGEventTap`
- **Accessibility**: reading and moving other apps' windows and pressing their menu items
- **Private APIs**: SkyLight and `_AXUIElementGetWindow`
- **Update path**: how Sparkle fetches, verifies, and installs updates

## Safeguards

- **Signed updates**: Sparkle installs only updates with a valid EdDSA signature. The appcast must be signed too (`SURequireSignedFeed`), and archives are verified before extraction (`SUVerifyUpdateBeforeExtraction`). The public key (`SUPublicEDKey`) is published in `Resources/sparkle-public-key.txt`.
- **Hardened Runtime**: enabled for every signed build.
- **No data collection**: no analytics or usage reporting. The only network access is the update check.
- **Key monitoring**: key events are only compared with the configured shortcuts and are never stored or sent.
- **Private APIs**: looked up at runtime, so the app keeps working where they are missing.
