# Nexus Connect setup

Nexus Connect uses Tailscale only as the private network path. Nexus also authenticates a pinned device identity, proves a separate per-device Keychain secret, negotiates a compatible protocol, and encrypts every application frame.

Pairing is a one-time operation. Restarting Nexus or either Mac does not require a new code.

## Requirements and honest limits

- Install Nexus on the MacBook and every Mac that will host work.
- Sign all devices into the same Tailscale tailnet.
- A host must be powered on, awake enough to accept network traffic, connected to Tailscale, and running the Nexus Connect LaunchAgent.
- The visible Nexus window does **not** need to remain open on a host.
- A sleeping, powered-off, offline, or never-installed Mac is shown as offline; Nexus cannot wake or reach it by pretending otherwise. Tailscale itself cannot power on a Mac. Wake-on-LAN needs a separate always-on device on the destination LAN and compatible Mac power settings, so it is not treated as a safe baseline capability.
- Compatible Nexus versions can connect even when their commits differ. A feature introduced by a newer protocol is disabled when necessary. Only a complete lack of protocol overlap requires an upgrade.
- The host LaunchAgent waits and retries when Tailscale is temporarily stopped or still starting during login.

Nexus finds the Tailscale CLI in `/opt/homebrew/bin`, `/usr/local/bin`, or the Tailscale app bundle.

## Build and run on each Mac

Clone this private repository on the MacBook, Mac Studio, and iMac. From the repository root on each device:

```bash
./scripts/build-nexus.sh --run
```

With Xcode, open `nexus/nexus.xcodeproj`, select the `nexus` scheme and the current Mac, and press Run.

### Stable local signing and Keychain access

Nexus's macOS Debug and Release builds embed the explicit designated
requirement `identifier "na.nexus"`. This keeps the permission identity stable
when the executable CDHash changes and requires no local certificate or
Keychain trust operation. `./scripts/build-nexus.sh` verifies the complete
signature and exact requirement before it can run the app.

Each Mac still requires its own one-time macOS privacy grants. Do not delete
`na.nexus.connect` Keychain items because they contain the saved device
identity and pairing records.

## Pair the Mac Studio once

1. On the Studio, open the model window and expand **Nexus Connect**.
2. Set **Role** to **Offer this Mac** and enable it.
3. Click **Create one-time pairing code**, then **Copy**. The `NX2...` code is a secret; do not put it in chat, logs, or source control.
4. On the MacBook, set the role to **Use paired Macs**, paste the code, and click **Pair device**.
5. The Studio appears in the MacBook's saved device roster. The code is never needed again.

The Studio installs a per-user LaunchAgent named `na.nexus.connect-host`. Quitting or rebuilding the visible Studio UI does not stop the listener or an in-progress host-owned model download.

## Pair the iMac once

Repeat the same five steps on the iMac. Generate a new code on the iMac; do not reuse the Studio code. The MacBook then retains two independent records with different secrets and pinned identities.

The MacBook automatically reconnects to both hosts. Use **Rename**, **Reconnect**, or **Forget** on each saved device independently. **Forget** deletes only that relationship and prevents its old credential from reconnecting. On a host, **Revoke** performs the matching host-side revocation for an authorized client.

## Choose where models run and download

The model window has two separate controls:

- **Run models on**: **Automatic**, **This Mac**, Mac Studio, or iMac.
- **Download to**: **Automatic** or one or more checked concrete destinations. A model can be downloaded directly to both Studio and iMac in one operation.

Automatic first chooses a healthy node that already owns the selected model. If a model must be placed, it chooses a healthy node with sufficient reported memory and disk. RAM is not added across computers: one model process runs on one selected Mac, so a 24 GB MacBook plus a 128 GB Studio does not become a single 152 GB memory pool.

For a selected remote destination, model bytes travel from the model provider directly to that host's disk. They are never proxied through the MacBook. A remote pull never falls back to the MacBook.

Every remote download re-probes the destination rather than trusting cached inventory. Existing compatible Ollama or LM Studio installations are used immediately. If an explicit Ollama download finds neither runtime, that same download action provisions the supported default Ollama runtime and continues—there is no second confirmation. Missing-runtime errors include the Ollama, LM Studio, and MLX probe result. Nexus never silently changes the selected model's runtime. Inventory refreshes after every pull or delete.

## Status meanings

| Status | Meaning |
| --- | --- |
| online | A fresh authenticated health check succeeded |
| reconnecting | Nexus is retrying with bounded exponential backoff |
| offline | Tailscale or the host helper cannot currently be reached |
| incompatible | The app protocol ranges do not overlap; pairing is retained |
| revoked | That credential is intentionally denied |

An identity-key mismatch is never accepted silently. Forget/revoke the old relationship and pair intentionally only after verifying why the host identity changed.

## Runtime and host diagnostics

Check the tailnet and each route:

```bash
/opt/homebrew/bin/tailscale status
/opt/homebrew/bin/tailscale ping <host-magic-dns-name>
```

Use `/usr/local/bin/tailscale` if that is where it is installed. Host state and logs are stored at:

```text
~/Library/Application Support/Nexus/ConnectHost/status.json
~/Library/Application Support/Nexus/ConnectHost/host.log
~/Library/Application Support/Nexus/ConnectHost/host-error.log
```

Inspect the LaunchAgent:

```bash
launchctl print gui/$(id -u)/na.nexus.connect-host
```

## Verification

Run the app unit suite:

```bash
xcodebuild test \
  -project nexus/nexus.xcodeproj \
  -scheme nexus \
  -destination 'platform=macOS' \
  -only-testing:nexusTests
```

Run UI tests with normal signing enabled:

```bash
xcodebuild test \
  -project nexus/nexus.xcodeproj \
  -scheme nexus \
  -destination 'platform=macOS' \
  -only-testing:nexusUITests
```
