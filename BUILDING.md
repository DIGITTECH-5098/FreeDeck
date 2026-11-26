# Building & Sideload Guide

FreeDeck builds as an **unsigned** IPA on purpose: it is signed at install time
with whatever free method you choose (free Apple ID, SideStore/AltStore, or
TrollStore). No paid developer certificate is ever required.

FreeDeck requires **iOS 16+** (the deployment target was raised from 15.0 for
the new modules).

## 1. Build with GitHub Actions (recommended)

This repository ships `.github/workflows/build.yml`, which produces the IPA on
macOS runners — no Mac of your own needed.

1. Push the repository to GitHub (or fork it).
2. Open the **Actions** tab → **Build FreeDeck IPA** → **Run workflow**
   (it also runs automatically on every push to `main` and on pull requests).
3. When the run finishes, download the **`FreeDeck.ipa`** artifact from the
   run summary page.
4. Optional releases: push a tag like `v0.1.0` and the workflow attaches
   `FreeDeck.ipa` to a GitHub Release automatically. The AltStore source
   (`.github/apps.json`) is refreshed from the release by the
   **Update AltStore Source** workflow.

> The workflow selects the newest Xcode on the runner automatically. The
> bundled `StikJIT.xcframework` was built with a Swift 6.4 (Xcode 27)
> toolchain and ships textual module interfaces; if the runner's compiler
> cannot consume them, the job fails with the import error rather than
> producing a broken IPA.

## 2. Build locally (Xcode)

Requirements: macOS with Xcode 27+ (for `StikJIT.xcframework`), git with
submodules.

```bash
git clone --recurse-submodules https://github.com/DIGITTECH-5098/FreeDeck.git
cd FreeDeck

xcodebuild clean archive \
  -project "LiveContainer.xcodeproj" \
  -scheme "LiveContainer" \
  -configuration Release \
  -archivePath "$PWD/build/FreeDeck.xcarchive" \
  -destination "generic/platform=iOS" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

mkdir -p build/Payload
cp -R build/FreeDeck.xcarchive/Products/Applications/FreeDeck.app build/Payload/
(cd build && zip -qr FreeDeck.ipa Payload)
```

Or just open `LiveContainer.xcodeproj` in Xcode, select the `LiveContainer`
scheme and **Product → Archive**, then export without signing.

## 3. Sideload / install

Pick any of these — all are free:

| Method | Signing | Expiry | Notes |
|---|---|---|---|
| **AltStore / SideStore** | free Apple ID | 7 days, refreshable | Add this repo's AltStore source or drop the IPA in manually |
| **TrollStore** | perma-signed | never | iOS 14.0–16.6.1 / 17.0 only |
| **Sideloadly / idevice + free Apple ID** | free Apple ID | 7 days | Re-sign weekly |
| **Enterprise/付费 certificate** | — | — | *Not needed; FreeDeck removed all certificate gates* |

Recommended on a low-storage device: SideStore + the pairing-file workflow
below, so FreeDeck can refresh its own signature on-device.

### Pairing file (certificate-free / JIT-less setup)

1. On a Linux/Mac/PC on the same network (or over Tailscale), generate a
   pairing record:
   ```bash
   pymobiledevice3 usbmux list              # find the device
   pymobiledevice3 lockdown pair            # writes a .mobiledevicepairing file
   # or with libimobiledevice:
   idevicepair pair
   ```
2. Copy the `.mobiledevicepairing` / `.plist` file to the iPhone
   (AirDrop, `scp` over Tailscale, Files app, …).
3. In FreeDeck: **Settings → Pairing** → **Import Pairing File** → pick the
   file. FreeDeck stores it in its sandbox and uses the loopback tunnel
   (`LoopbackVPN`, `127.0.0.1` / `fd00::`) to talk to `lockdownd` on-device.
4. **Settings → JIT** → *Built-in JIT* now attaches over the tunnel — no PC
   tether and no paid certificate.

## 4. Deploy the storage server

The iPhone side keeps only lightweight stubs; IPAs, game assets and web ports
live on your server (see `server/`).

```bash
cd server
cp .env.example .env        # set FREEDECK_STORAGE_ROOT, FREEDECK_TOKEN …
docker compose up -d        # FastAPI + Nginx (byte-range streaming)
# or without Docker:
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
FREEDECK_STORAGE_ROOT=/freedeck_storage .venv/bin/uvicorn server:app --host 0.0.0.0 --port 8080
```

Put the server on your Tailscale net (MagicDNS, e.g.
`freedeck.tailnet.ts.net`), then in FreeDeck set **Settings → Server
Library → Server URL** to `http://freedeck.tailnet.ts.net:8080`
(or whatever host/port you exposed). The app stores this under the
`freedeck.server` user-default key.

The server exposes:

- `GET /api/library` — catalog of IPAs, unpacked apps and web ports
- `POST /api/install` — download/extract a remote IPA or zip onto the server
- `GET /stream/<entry>/<path>` — HTTP byte-range streaming (206) for the LRU cache hooks
- `GET /webport/<entry>/` — hosted HTML5/WASM game ports with range support

See `server/README.md` for the full API.

## 5. What was removed from the upstream project

No store account, no subscription, no ban/status service, no checkout and
no paid certificate flow. See `AUDIT.md` for the complete list of modified
files and `README.md` for what FreeDeck adds (server library, web port runner,
remote storage hooks, pairing manager).
