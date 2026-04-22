# SimpleFIN bridge for Actual Budget

Freentonic ships an optional HTTP subsystem that speaks the
[SimpleFIN](https://www.simplefin.org/) wire protocol, so you can point a
self-hosted [Actual Budget](https://actualbudget.org/) server at freentonic
and get real bank transactions from whatever bank a provider YAML supports.

The subsystem is gated by `FREENTONIC_SIMPLEFIN_ENABLED=1`. When disabled,
no new routes are registered and no disk writes happen under the SimpleFIN
state directory — the container behaves exactly like before.

## What you get

One freentonic container becomes a SimpleFIN bridge:

```
Actual Budget  ──POST /simplefin/claim/<id>──▶  freentonic
                                                │
                                                ▼
Actual Budget  ──GET /simplefin/accounts/<k>──▶ freentonic
                  (HTTP Basic)                   │
                                                 ▼
                                           spawn Chrome,
                                           run workflow,
                                           cache transactions
```

Every bank is a separate *profile*. Each profile pins one workflow YAML
plus the credentials that workflow needs. You provision profiles through
a password-protected admin UI at `https://<your-host>/admin/`.

## Environment variables

Required when `FREENTONIC_SIMPLEFIN_ENABLED=1`:

| Name                         | Value                                                         |
| ---------------------------- | ------------------------------------------------------------- |
| `FREENTONIC_SECRETS_KEY`     | 32 random bytes, base64-encoded. **Catastrophic if leaked.**  |
| `FREENTONIC_ADMIN_PASSWORD`  | Admin UI + admin API bearer token. High-entropy.              |
| `FREENTONIC_PUBLIC_URL`      | The URL actual-server will reach (e.g. `https://f.example.com`). |

Optional:

| Name                           | Default                   | Purpose                        |
| ------------------------------ | ------------------------- | ------------------------------ |
| `FREENTONIC_SIMPLEFIN_ROOT`    | `/workspace/simplefin`    | Where state lives.             |

Generate a secrets key:

```sh
ruby -rsecurerandom -rbase64 -e 'puts Base64.strict_encode64(SecureRandom.random_bytes(32))'
```

Store it in a real secrets manager. Losing it makes every encrypted bank
credential on disk unrecoverable; leaking it decrypts them.

## Running the container

```sh
docker run --rm -d \
  --name freentonic \
  -p 127.0.0.1:7878:7878 \
  -p 127.0.0.1:6080:6080 \
  -v ~/freentonic/workflows:/home/freentonic/workflows:ro \
  -v ~/freentonic/chrome:/home/freentonic/.cache/freentonic/chrome \
  -v ~/freentonic/simplefin:/workspace/simplefin \
  -e FREENTONIC_VNC=1 \
  -e FREENTONIC_SIMPLEFIN_ENABLED=1 \
  -e FREENTONIC_SECRETS_KEY="$(cat ~/.secrets/freentonic.key)" \
  -e FREENTONIC_ADMIN_PASSWORD="$(cat ~/.secrets/freentonic-admin)" \
  -e FREENTONIC_PUBLIC_URL=https://freentonic.example.com \
  ghcr.io/germandz/freentonic:latest
```

The `/workspace/simplefin` bind mount holds encrypted credentials and the
state machine. Back it up.

## Connecting Actual Budget

1. Open `https://freentonic.example.com/admin/` and sign in with the admin
   password. (You will probably put freentonic behind a reverse proxy
   terminating TLS — do not expose it over plain HTTP with an admin
   password on the open internet.)
2. Click **+ New profile**. Pick the workflow YAML, set a lookback, save.
3. Click **Credentials**. Fill in the secrets the workflow declares.
4. Click **Setup token**. Copy the base64 token.
5. In Actual's *Bank Sync → SimpleFIN*, paste the setup token.
6. Click Actual's **Sync** button. The first call returns empty and schedules
   a sync. Click Sync again a minute later and the transactions arrive.

## Re-authentication (MFA, device trust)

When a bank's session expires freentonic flips the profile to
`needs_reauth`. The admin UI surfaces a **Re-authenticate (VNC)** button
that kicks off a headed sync. Connect to noVNC
(`http://localhost:6080/vnc.html`) and finish the login by hand. Chrome
device-trust is persisted in the chrome-profile bind mount, so subsequent
headless syncs succeed until the session expires again.

## Operational notes

- `FREENTONIC_SIMPLEFIN_ENABLED=1` *and* `FREENTONIC_VNC=1` should both be
  set for the re-auth workflow to function.
- The SimpleFIN mode's `GET /simplefin/accounts/:key` never blocks on
  Chrome — it enqueues a sync and returns immediately with an empty
  envelope. Actual's second poll gets the data.
- Only one Chrome runs at a time across *all* of `/invoke`, manual
  "Sync now", and auto syncs (same mutex that serializes `/invoke`).
- Tokens minted through **Rotate URL** invalidate the old access URL;
  you must re-link the profile in Actual.
