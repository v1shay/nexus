# Nexus automated testing

Nexus has two deliberate automation modes.

## Hermetic automation

Run this after a code change:

```bash
./scripts/test-nexus-automation.sh
```

Add `--ui` to run the typed-request lifecycle smoke test:

```bash
./scripts/test-nexus-automation.sh --ui
```

The script builds with the configured stable signing identity, then:

- runs the real headless Nex Computer registry and semantic tool-search path;
- uses a process-local in-memory credential store, so it cannot trigger a login-Keychain dialog or touch a connector token;
- verifies that store explicitly; and
- with `--ui`, starts an isolated Nexus process, submits a typed request through the same controller method used by the overlay, and verifies the request → activity → answer lifecycle.

Results are written under `.build/automation-results/` and are disposable.

The typed smoke responder is intentionally deterministic and offline. It proves the live typed-input state pipeline without pretending to validate a model, live connector, destructive operating-system action, or pixel-level window composition. Visual panel layout still needs a logged-in manual/visual QA pass because macOS blocks reliable synthetic interaction with an elevated notch panel.

## Typed Nexus requests

Open the normal Nexus notch overlay and use the `Ask Nex…` field at the bottom. Typed requests call the same finalized-request method used after speech recognition: they append the same conversation turn, enter the same streaming/tool/preview lifecycle, and use the selected live model in a normal launch. They do not start the microphone.

## Live end-to-end checks

Live model, web, connector, and computer-action tests are intentionally opt-in. They can cost money, read account data, or cause external actions. Run them only against a dedicated test account/workspace and confirm each preview; do not make them part of the default smoke test.

## Keychain behavior

Connector and cloud credentials remain in the local macOS login Keychain. They do not sync through the repository, and a cloned repository starts unconnected on another Mac.

If macOS repeatedly asks for the login-Keychain password after Xcode rebuilds, it is usually because the app’s code-signing requirement changed while an existing Keychain item is still ACL-bound to the old build. The safe repair is:

1. Keep the same bundle identifier and a stable signing identity for normal builds.
2. Remove the old Nexus Keychain item once, then reconnect that provider and choose **Always Allow** if macOS offers it.
3. Never replace credentials with a plaintext local cache just to suppress the prompt.

The automation profile avoids that prompt only inside its own process-local test store; it does not bypass Keychain protections in the normal app.
