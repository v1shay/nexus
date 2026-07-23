# Nexus connector registration

Nexus keeps provider **account tokens** in the macOS Keychain service
`na.nexus.connectors.oauth` and provider **app-registration secrets** in the
separate device-local Keychain service `na.nexus.connectors.registration`.
Neither category belongs in source control, `Info.plist`, UserDefaults, the
Obsidian vault, or a synced folder.

## Redirect architecture

The registered web redirect URI for Notion, Slack, and GitHub is:

```text
https://v1shay.github.io/nexus/callback.html
```

`docs/callback.html` is a deliberately tiny HTTPS-to-native callback bridge.
It forwards only `code`, `state`, `error`, and `error_description` to
`na.nexus.oauth://oauth/callback`. Nexus then validates the custom scheme,
host, path, and original CSRF state before exchanging the code. The static
page never stores, logs, or exchanges tokens.

Google remains a native desktop OAuth client and uses the app custom scheme
directly; do not configure the GitHub Pages URI for that client.

## Provider console values

Configure the following before pressing **Connect** in Nexus:

| Provider | OAuth redirect | Notes |
| --- | --- | --- |
| Notion | `https://v1shay.github.io/nexus/callback.html` | The public connection must allow the workspace you choose. |
| Slack | `https://v1shay.github.io/nexus/callback.html` | Add user-token scopes matching the Nexus toggles, at minimum a read scope and `chat:write` only when needed. |
| GitHub App | `https://v1shay.github.io/nexus/callback.html` | Enable user authorization for the app and keep its installation permissions least-privilege. |
| Google desktop | `na.nexus.oauth://oauth/callback` | Enable Gmail, Calendar, and People APIs individually in Google Cloud. |

The GitHub Pages endpoint must actually be deployed before web OAuth is used.
The GitHub API currently reports no Pages site for either `v1shay/nexus` or
`v1shay/nexusV2`, so this repository cannot honestly claim that the URI is
live yet. Publish the `docs/` folder from the repository that owns the
`v1shay.github.io/nexus` site, then open the callback URL once and verify it
loads before connecting a provider.

## Local registration state

This Mac has local Keychain registrations for Notion, Slack, and GitHub,
including the GitHub App identifier and PEM key. The app reads them only when
beginning OAuth or app authentication; they are not emitted in diagnostics.

Discord is intentionally not a connected Nexus provider. Use Nexus's managed
browser for Discord workflows; Nexus does not keep Discord user credentials or
operate a self-bot.

## Rotate exposed values

Any client secret, signing secret, verification token, or private key shown in
a screenshot or pasted into a chat should be considered exposed. Regenerate
those values in the provider dashboard, replace the corresponding local
Keychain item, and revoke old tokens after confirming the replacement works.
