# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

- GitHub: **Security → Report a vulnerability** on this repository (private advisory), or
- email **john@elier.ai** with "Otto security" in the subject.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get a
reply within a few days. Please give a reasonable window to ship a fix before publishing details.

## Scope

- The apps in `ios/` (iPhone, iPad, Mac, Watch, Apple TV, widgets, share extension).
- The relay in `relay/` and the helpers in `netwatch/` and `scripts/`.

Hermes Agent itself is a separate project; report issues in it to the Hermes maintainers.

## How Otto is meant to be deployed

- The relay listens on `127.0.0.1` only and is published to your own devices with Tailscale Serve
  (tailnet only; never Tailscale Funnel or a public port forward).
- Every relay route except `/health` and the pairing routes requires `Authorization: Bearer
  <API_SERVER_KEY>`. That key can open a login shell on the Hermes Mac through the Terminal pane,
  so treat it like an SSH key: keep it in `~/.hermes/.env`, rotate it if a paired device is lost.
- Pairing (`/tvpair/*`, `/macpair/*`) only releases the key after an on-screen click on the Mac or
  approval from an already-connected device. `/macpair/*` accepts direct loopback clients only.
- The apps keep the relay key and the Weft token in the Keychain (this device only).
