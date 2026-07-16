# Nexus Connect setup

Nexus Connect uses Tailscale for transport and a separate app-level encrypted session for authorization and payload protection. Initial pairing is intentional; after that, connection, discovery, health checks, and reconnection happen whenever Nexus is open on both Macs.

## Requirements

- The MacBook Air and Mac Studio are signed into the same Tailscale tailnet.
- Both Macs run the same Nexus commit/build.
- Nexus remains open on the Studio while the Air delegates work.
- For model work, install Ollama or LM Studio on the Studio. Nexus starts the selected runtime when needed.
- Keep the Studio awake and give it enough free disk for large models. A 120B+ quantized model can require tens of gigabytes of RAM and considerably more disk; the exact requirement depends on its quantization and context size.

Nexus looks for the Tailscale CLI at `/opt/homebrew/bin/tailscale`, `/usr/local/bin/tailscale`, or inside `/Applications/Tailscale.app`.

## Build the same app on both Macs

From the repository root:

```bash
./scripts/build-nexus.sh
open .build/Build/Products/Debug/nexus.app
```

To open the project in Xcode instead:

```bash
open nexus/nexus.xcodeproj
```

Select the `nexus` scheme and the local Mac, then press Run. The minimum deployment target remains macOS 14.2, preserving the existing app target.

## Pair once

1. On the Mac Studio, open Nexus's model window, expand **Nexus Connect**, and choose **This is the Mac Studio**.
2. Press **Generate**, then **Copy**. Treat the `NX1...` value like a password; do not paste it into chat, logs, or source control.
3. On the MacBook Air, open the same panel, choose **Use Mac Studio**, paste the code, and press **Pair**.
4. Turn on **Enable automatically** on the Studio, then on the Air.
5. The Studio should say `Studio host is ready on Tailscale`. The Air progresses through finding, connecting, and then `Connected to … · <RAM> GB · <latency> ms`.

The first authenticated connection pins each device's Ed25519 identity. A later identity mismatch is not silently accepted: press **Unpair** on both Macs and intentionally pair again.

## Normal use

- Leave Nexus open on both Macs. No Terminal window is opened and no reconnection action is required.
- On the Air, select or search for a model in the existing model window. When Connect is ready, downloads run on the Studio and recommendations use Studio RAM.
- Selecting the downloaded model makes it the current Nexus model. The existing notch response, token streaming, pet thinking animation, Markdown rendering, and Piper speech path remain unchanged; only the compute placement changes.
- If the Studio sleeps or the network disappears, safe idempotent work falls back locally when the Air can satisfy it. Nexus reconnects in the background with bounded exponential backoff.
- Remote-only operations such as a 120B model pull never silently download that model onto the Air.

## Files and downloads

The default Studio host exposes named, validated roots rather than arbitrary absolute paths:

- `home`: the Studio user's home folder
- `downloads`: the Studio user's Downloads folder
- `nexus`: `~/Nexus`

Transfers use an authenticated transfer ID, bounded chunks, per-chunk SHA-256, a persistent resume manifest, whole-file SHA-256, and atomic final rename. Interrupted transfers continue when the caller reuses the same transfer ID. Internal transfer files reject symlinks.

Remote URL downloads accept HTTPS only. Resumption uses HTTP Range when the origin supports it. Nexus does not claim to bond the Air and Studio connections; the speed benefit comes from placing the download and storage on the Studio when that path is faster.

## Approved code and command work

Nexus does not accept arbitrary shell strings, `zsh -c`, `sh -c`, or model-generated command text. A process request specifies an allowlisted executable ID, an argument array, an allowed working-directory token, a timeout, and an output limit.

The Air shows a **Run Once** confirmation. If accepted, the Studio issues a short-lived single-use token. The default executable IDs are `git`, `swift`, `xcodebuild`, `python3`, and `rg`; availability still depends on that exact binary existing on the Studio. Shell interpreters remain blocked even if misconfigured into the allowlist.

## Recommended Tailscale policy

Nexus rejects non-tailnet source addresses and still authenticates/encrypts at the app layer. Also restrict TCP port `49718` in your tailnet policy. A tag-based Grants example is:

```json
{
  "tagOwners": {
    "tag:nexus-air": ["autogroup:admin"],
    "tag:nexus-studio": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["tag:nexus-air"],
      "dst": ["tag:nexus-studio"],
      "ip": ["tcp:49718"]
    }
  ]
}
```

Merge this with your current policy rather than replacing unrelated rules. Apply the two tags to the intended devices in the Tailscale admin console.

## Diagnostics

Verify both peers and the current route:

```bash
/usr/local/bin/tailscale status
/usr/local/bin/tailscale ping <studio-magic-dns-name>
```

If your CLI is in `/opt/homebrew/bin`, use that path instead. A direct connection normally has the best latency. Peer relay or DERP remains encrypted but Nexus automatically uses smaller chunks and less bulk concurrency.

Common status messages:

| Status | Meaning | Action |
| --- | --- | --- |
| Pairing code required | The selected role has no Keychain secret | Generate on one Mac and pair the other |
| Finding your Mac Studio | Tailscale discovery is running | Confirm both peers are online |
| Reconnecting | Health check or session failed | Nexus retries automatically; check Studio sleep/Tailscale |
| Identity changed | The pinned device key differs | Unpair both sides and intentionally re-pair |
| Studio host could not start | Port `49718` could not bind | Quit duplicate Studio builds, then reopen one Nexus instance |

## Verification commands

Run unit regressions:

```bash
xcodebuild test \
  -project nexus/nexus.xcodeproj \
  -scheme nexus \
  -destination 'platform=macOS' \
  -only-testing:nexusTests
```

Run signed UI and launch tests (do not disable code signing for the UI runner):

```bash
xcodebuild test \
  -project nexus/nexus.xcodeproj \
  -scheme nexus \
  -destination 'platform=macOS' \
  -only-testing:nexusUITests
```
