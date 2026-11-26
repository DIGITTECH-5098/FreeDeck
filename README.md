<div align="center">
  <h1>FreeDeck</h1>
  <p><strong>Your apps. Your server. Zero local storage.</strong></p>
  <p>A free, open-source app environment for iOS — no subscription, no account, no paid certificates.</p>
</div>

FreeDeck is a completely free fork of **FlekDeck** (by FlekStore) and
[LiveContainer](https://github.com/LiveContainer/LiveContainer): a multi-window,
SpringBoard-style launcher that runs apps, games and web ports inside its own
environment on iOS.

The fork is engineered for **low-storage devices** (e.g. a 64 GB iPhone):
instead of keeping heavy IPAs, game assets or web-port data on the phone,
FreeDeck offloads installation and storage to **your own Linux server**
(a 240 GB pool works nicely) over **Tailscale + HTTP byte-range streaming** —
while the native, multi-window launcher experience stays on-device.

> [!NOTE]
> FreeDeck runs apps inside its own environment. It is an app launcher,
> not an emulator or a virtual machine.

## What the fork changed

- **All paywalls removed.** No FlekStore account, no subscription, no ban/status
  service, no checkout, no paid developer certificates. Everything is unlocked;
  see [AUDIT.md](./AUDIT.md) for the complete file-by-file record.
- **Self-hosted server backend** (`server/`): FastAPI + Nginx with byte-range
  streaming, a REST catalog, remote IPA/zip install and web-port hosting.
- **Zero-local-storage streaming**: guest apps keep only lightweight stubs
  (< 15 MB); large assets (`.obb`, `.pak`, …) stream on demand through an
  injected filesystem hook (`RemoteStorageHook.m`) with a 1 GB auto-evicting
  LRU cache.
- **Web ports**: HTML5/WASM game ports render in a hardware-accelerated
  `WKWebView` with virtual gamepad overlay and MFi/Bluetooth controller
  support (Xbox/PlayStation via `GCController`).
- **Pairing-file JIT setup** (`PairingManager.swift`): import a
  `.mobiledevicepairing` file generated with `pymobiledevice3`/`idevicepair`
  and attach JIT on-device over the loopback tunnel — no PC tethering, no paid
  certificate.
- **Built-in location spoofer**: system-wide GPS simulation over the local
  `RemoteXPC`/DVT bridge (`LocationSimulation`), with a map pin-dropper and
  GPX playback in the quick menu. Free, like everything else.
- **Server Library tab**: browse, install and launch directly on the server
  with zero local storage impact.

## Repository layout

| Path | What it is |
|---|---|
| `LiveContainerSwiftUI/FreeDeck/` | New FreeDeck modules: `PairingManager.swift`, `RemoteStorageHook.m/.h`, `ServerLibraryView.swift`, `WebPortRunnerView.swift` |
| `LiveContainerSwiftUI/FreeDeckStore/` | Rebranded store/catalog models (paywall logic removed) |
| `server/` | FastAPI + Nginx + Docker remote-storage backend (see `server/README.md`) |
| `BUILDING.md` | Build & sideload guide (GitHub Actions IPA, Xcode, signing, pairing) |
| `AUDIT.md` | Full fork audit: every modified, renamed, deleted and added file |

## Quick start

1. **Build the IPA** — push to GitHub and let the Actions workflow build
   `FreeDeck.ipa`, or build locally with Xcode. See [BUILDING.md](./BUILDING.md).
2. **Deploy the server** — `cd server && docker compose up -d` (or uvicorn
   directly), expose it on your Tailscale net.
3. **Sideload FreeDeck** with AltStore/SideStore/TrollStore (all free), set the
   server URL in *Settings → Server Library*, and import a pairing file for
   certificate-free JIT.

## Compatibility & privacy

FreeDeck contains extensive fixes for apps and games that do not run correctly
in the original LiveContainer. Because apps differ in their frameworks,
entitlements, extensions and system-service requirements, compatibility cannot
be guaranteed for every app. Apps running inside a container may not be
isolated from one another the way separately installed iOS apps are — only
install software from developers and repositories you trust.

## Credits

- [FlekDeck](https://github.com/flekstore/FlekDeck) by FlekStore — the
  launcher, home screen, multitasking and installer this fork is built on.
- [LiveContainer](https://github.com/LiveContainer/LiveContainer) — the core
  container engine both projects derive from.
- Third-party components and their licenses:
  [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).

## License

FreeDeck is free software distributed under the
[GNU Affero General Public License v3.0](./LICENSE) (inherited from upstream).
The corresponding source code for this version of FreeDeck is available at
[this repository](https://github.com/DIGITTECH-5098/FreeDeck).
