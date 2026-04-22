# SimpleFIN bridge for Actual Budget — operator guide

This is the end-to-end deployment guide for running freentonic as a
[SimpleFIN](https://www.simplefin.org/) bridge in front of a self-hosted
[Actual Budget](https://actualbudget.org/) install.

It covers everything from building the Docker image to pasting the
setup token into Actual and watching the first transactions arrive. If
you already have the invoke-server running in Docker, you can skip to
[Step 3 — Enable SimpleFIN mode](#step-3--enable-simplefin-mode).

## Table of contents

1. [What you'll build](#1-what-youll-build)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Clone + build the image](#step-1--clone--build-the-image)
4. [Step 2 — Generate secrets](#step-2--generate-secrets)
5. [Step 3 — Enable SimpleFIN mode](#step-3--enable-simplefin-mode)
6. [Step 4 — Verify the container is healthy](#step-4--verify-the-container-is-healthy)
7. [Step 5 — Provision a bank profile](#step-5--provision-a-bank-profile)
8. [Step 6 — Connect Actual Budget](#step-6--connect-actual-budget)
9. [Step 7 — Configure optional auto-sync](#step-7--configure-optional-auto-sync)
10. [Re-authentication via VNC (MFA, expired sessions)](#re-authentication-via-vnc)
11. [Running behind a reverse proxy (recommended)](#running-behind-a-reverse-proxy)
12. [Backup, rotation, and disaster recovery](#backup-rotation-and-disaster-recovery)
13. [Troubleshooting](#troubleshooting)
14. [Reference: environment variables](#reference-environment-variables)
15. [Reference: admin REST API](#reference-admin-rest-api)

---

## 1. What you'll build

```
┌─────────────────────┐        HTTPS         ┌─────────────────────────┐
│ Actual Budget       │ ──────────────────▶ │ freentonic (Docker)     │
│ self-hosted         │   Basic auth         │ ├─ /simplefin/accounts/ │
└─────────────────────┘                      │ ├─ /simplefin/claim/    │
      ▲                                      │ ├─ /admin/              │
      │  pastes setup token                  │ └─ /invoke              │
      │                                      └───────┬─────────────────┘
┌─────┴───────────────┐                              │ spawns headed Chrome
│ Operator (you)      │  HTTPS to /admin/            ▼
│ — provisions        │  ───────────────▶   ┌─────────────────────────┐
│   profiles          │                      │ Chrome inside Xvfb      │
│ — completes VNC     │  noVNC 6080 ────────▶│ + optional VNC / noVNC  │
│   re-auth           │                      │ (runs the workflow)     │
└─────────────────────┘                      └─────────────────────────┘
```

One Docker container holds everything: the invoke server, an admin UI
for managing bank profiles, the SimpleFIN protocol adapter, and a
headed Chrome session driven by your freentonic-providers YAMLs. Each
bank you want to sync becomes one **profile** in the admin UI.

---

## 2. Prerequisites

- **Docker 20.10+** (Linux host, Docker Desktop on macOS/Windows with
  WSL2 also works).
- **Workflow YAMLs for your banks.** Either:
  - Clone [`freentonic-providers`](https://github.com/GermanDZ/freentonic-providers)
    to a directory on the host and point freentonic at it, **or**
  - Author your own provider YAML — see [writing-plugins.md](writing-plugins.md).
- **A self-hosted Actual Budget server** (the web UI / sync server, not
  just the desktop app). See
  [actualbudget.org/docs/install](https://actualbudget.org/docs/install/).
- **A public hostname** for freentonic that Actual can reach. If
  Actual is on the same machine, `http://127.0.0.1:7878` is fine for
  local experiments; otherwise put a reverse proxy with TLS in front
  (see [Step 11](#running-behind-a-reverse-proxy)).
- **~500 MB free disk** for the image, plus a few hundred KB per profile
  for the encrypted state dir.

The container's bind mounts you'll need on the host:

| Host directory                  | Container path                                   | Purpose |
| ------------------------------- | ------------------------------------------------ | ------- |
| `~/freentonic/workflows/`       | `/home/freentonic/workflows` (ro)                | Provider YAMLs. |
| `~/freentonic/runs/`            | `/workspace/runs`                                | Per-sync logs and artifacts. |
| `~/freentonic/simplefin/`       | `/workspace/simplefin`                           | Encrypted profiles + state + cache. **Back this up.** |
| _Docker volume_                 | `/home/freentonic/.cache/freentonic/chrome`      | Chrome profile for bank device-trust. Named volume so sessions survive container restarts. |

---

## Step 1 — Clone + build the image

```sh
git clone https://github.com/GermanDZ/freentonic.git
cd freentonic
docker build -t freentonic:latest .
```

The image is based on `ruby:3.2-slim-bookworm` and bundles Chromium,
Xvfb, x11vnc, noVNC, and tini. Zero runtime gem dependencies — the
framework stays pure stdlib.

Get your workflows:

```sh
mkdir -p ~/freentonic
git clone https://github.com/GermanDZ/freentonic-providers ~/freentonic/workflows
```

---

## Step 2 — Generate secrets

SimpleFIN mode needs **three** secrets from you before it will start:

### 2a. Master encryption key — `FREENTONIC_SECRETS_KEY`

A 32-byte random key, base64-encoded. Used to derive AES-256-GCM subkeys
for every bank credential stored on disk. **Losing this key makes every
encrypted credential unrecoverable. Leaking it decrypts them.**

Generate it once and keep it in a real secrets manager (1Password,
Bitwarden, `pass`, AWS Secrets Manager, a file with mode 0400 on a
locked-down host…):

```sh
ruby -rsecurerandom -rbase64 \
  -e 'puts Base64.strict_encode64(SecureRandom.random_bytes(32))'
```

You should get something that looks like:

```
iQZ0X4Wn0Vw2ZDO3x7hH2pAeFBvJgs9y8VJwkJhPqEs=
```

Save it as `~/.secrets/freentonic.master-key`. Do **not** commit it.

### 2b. Admin password — `FREENTONIC_ADMIN_PASSWORD`

Protects the admin UI at `/admin/` and every `/admin/api/*` endpoint.
Use a high-entropy value:

```sh
ruby -rsecurerandom -e 'puts SecureRandom.base64(24)'
```

Save it as `~/.secrets/freentonic.admin-password`.

### 2c. Invoke token — `FREENTONIC_INVOKE_TOKEN`

This one already exists from any pre-SimpleFIN deployment. If you
don't have one yet, generate it:

```sh
openssl rand -hex 32 > ~/.secrets/freentonic.invoke-token
```

### 2d. Public URL — `FREENTONIC_PUBLIC_URL`

The URL Actual will reach. Important: this is what gets embedded into
the setup token you give to Actual, so it has to be resolvable from
Actual's network.

- **Localhost experiment:** `http://127.0.0.1:7878`
- **LAN / home-server:** `http://192.168.1.50:7878`
- **Production:** `https://freentonic.yourdomain.example`

No trailing slash.

---

## Step 3 — Enable SimpleFIN mode

The `docker-run-freentonic.sh` wrapper knows about SimpleFIN. Export the
five env vars and run `./docker-run-freentonic.sh server`:

```sh
export FREENTONIC_WORKFLOWS_DIR=~/freentonic/workflows
export FREENTONIC_RUNS_DIR=~/freentonic/runs
export FREENTONIC_INVOKE_TOKEN="$(cat ~/.secrets/freentonic.invoke-token)"

export FREENTONIC_SIMPLEFIN_ENABLED=1
export FREENTONIC_SIMPLEFIN_DIR=~/freentonic/simplefin
export FREENTONIC_SECRETS_KEY="$(cat ~/.secrets/freentonic.master-key)"
export FREENTONIC_ADMIN_PASSWORD="$(cat ~/.secrets/freentonic.admin-password)"
export FREENTONIC_PUBLIC_URL="http://127.0.0.1:7878"

./docker-run-freentonic.sh server
```

You should see:

```
SimpleFIN bridge enabled (state dir: /home/you/freentonic/simplefin)
starting freentonic-server (workflows=…, runs=…)
<container_id>
listening on http://127.0.0.1:7878
admin UI at http://127.0.0.1:7878/admin/ (password: $FREENTONIC_ADMIN_PASSWORD)
noVNC at http://127.0.0.1:6080/vnc.html?host=localhost&port=6080&password=freentonic&autoconnect=true
```

### Without the wrapper (raw `docker run`)

Same behavior, explicit form. Useful if you're integrating with
systemd, a Compose file, or a container orchestrator:

```sh
docker run -d \
  --name freentonic-server \
  --restart unless-stopped \
  -p 127.0.0.1:7878:7878 \
  -p 127.0.0.1:6080:6080 \
  -v ~/freentonic/workflows:/home/freentonic/workflows:ro \
  -v ~/freentonic/runs:/workspace/runs \
  -v ~/freentonic/simplefin:/workspace/simplefin \
  -v freentonic-chrome-profile:/home/freentonic/.cache/freentonic/chrome \
  --shm-size=256m \
  -e FREENTONIC_INVOKE_TOKEN="$(cat ~/.secrets/freentonic.invoke-token)" \
  -e FREENTONIC_VNC=1 \
  -e FREENTONIC_SIMPLEFIN_ENABLED=1 \
  -e FREENTONIC_SECRETS_KEY="$(cat ~/.secrets/freentonic.master-key)" \
  -e FREENTONIC_ADMIN_PASSWORD="$(cat ~/.secrets/freentonic.admin-password)" \
  -e FREENTONIC_PUBLIC_URL="http://127.0.0.1:7878" \
  freentonic:latest
```

### Minimal `docker-compose.yml`

```yaml
services:
  freentonic:
    image: freentonic:latest
    container_name: freentonic-server
    restart: unless-stopped
    ports:
      - "127.0.0.1:7878:7878"
      - "127.0.0.1:6080:6080"
    volumes:
      - ~/freentonic/workflows:/home/freentonic/workflows:ro
      - ~/freentonic/runs:/workspace/runs
      - ~/freentonic/simplefin:/workspace/simplefin
      - chrome_profile:/home/freentonic/.cache/freentonic/chrome
    shm_size: "256m"
    environment:
      FREENTONIC_INVOKE_TOKEN: ${FREENTONIC_INVOKE_TOKEN}
      FREENTONIC_VNC: "1"
      FREENTONIC_SIMPLEFIN_ENABLED: "1"
      FREENTONIC_SECRETS_KEY: ${FREENTONIC_SECRETS_KEY}
      FREENTONIC_ADMIN_PASSWORD: ${FREENTONIC_ADMIN_PASSWORD}
      FREENTONIC_PUBLIC_URL: ${FREENTONIC_PUBLIC_URL}

volumes:
  chrome_profile:
```

Put the five secrets in an adjacent `.env` file (mode 0600, gitignored):

```env
FREENTONIC_INVOKE_TOKEN=…
FREENTONIC_SECRETS_KEY=…
FREENTONIC_ADMIN_PASSWORD=…
FREENTONIC_PUBLIC_URL=https://freentonic.yourdomain.example
```

---

## Step 4 — Verify the container is healthy

```sh
curl -s http://127.0.0.1:7878/healthz
# {"ok":true,"in_flight":0,"shutting_down":false}
```

Check the admin UI with a web browser:

```
http://127.0.0.1:7878/admin/
```

You should get a **Freentonic — SimpleFIN bridge** sign-in page. Enter
your admin password and you should land on an empty profiles list.

If anything goes wrong, tail the container logs:

```sh
./docker-run-freentonic.sh logs
# or
docker logs -f freentonic-server
```

Common startup-time errors:

| Log line                                                           | Fix |
| ------------------------------------------------------------------ | --- |
| `simplefin: FREENTONIC_SIMPLEFIN_ENABLED=1 requires: …`            | Set the listed env var. |
| `simplefin: FREENTONIC_SECRETS_KEY invalid: master key must decode to 32 bytes` | Re-generate with the Step 2a command — your key wasn't base64 or was the wrong length. |
| `workflows directory /home/freentonic/workflows is empty`          | Bind-mount your workflow YAMLs at that path. |

---

## Step 5 — Provision a bank profile

The admin UI is the easiest path. At `http://127.0.0.1:7878/admin/`:

### 5a. Click **+ New profile**

Fill in:

| Field                    | Value |
| ------------------------ | ----- |
| Profile key              | A short stable identifier, e.g. `ing_personal`. Used in filenames + URLs. Charset: `[A-Za-z0-9_.-]{1,128}`. |
| Display name             | Human label, e.g. `ING — personal account`. |
| Workflow                 | Pick from the dropdown (populated from your workflows directory). |
| Lookback (days)          | How far back each sync pulls (default 30). |
| Auto-sync interval       | Leave blank for now. See [Step 7](#step-7--configure-optional-auto-sync). |

Click **Create**. A new row appears in the profiles list with state
`idle`.

> **Note on the profile key.** It also becomes the Chrome profile
> subdirectory for that bank, so two profiles that share a `profile_key`
> would share Chrome device-trust. Don't reuse keys across banks.

### 5b. Click **Credentials**

The form fields match the `source.credentials` block of your chosen
workflow YAML — freentonic reads them at runtime so you see exactly the
secrets your workflow declared, e.g. `USER_DNI` and `USER_PIN` for a
Spanish bank.

Enter the live bank credentials, click **Save**. They are encrypted
with AES-256-GCM under a per-profile subkey derived from
`FREENTONIC_SECRETS_KEY` and written to
`~/freentonic/simplefin/profiles/<key>.json`. Never stored in
plaintext, never logged, never passed on argv.

To rotate: just run the same form again with new values. The old
ciphertext is overwritten atomically.

### 5c. Click **Setup token**

Freentonic mints a one-shot claim URL, base64-encodes it, and shows it
in a read-only textbox. **Copy the token** (the **Copy** button uses the
clipboard API).

Two important properties:

- **TTL: 10 minutes.** After that the claim expires.
- **Single-use.** Once Actual exchanges it for an access URL, the
  token is consumed.

If you need another one, click Setup token again — the old claim stays
valid until its TTL expires or someone consumes it, whichever comes
first. The **Rotate URL** button invalidates any already-issued access
URL, forcing a fresh claim.

---

## Step 6 — Connect Actual Budget

In Actual (browser UI, self-hosted):

1. Top-right menu → **Settings** → **Advanced settings**.
2. Scroll to **Bank sync**. Make sure **SimpleFIN** is enabled.
3. Top of the **Accounts** sidebar → **Add account** → **Link bank
   account** → **SimpleFIN**.
4. In the *Token* field, paste the base64 setup token you copied.
5. Click **Link**. Actual will:
   - `POST` the claim URL (freentonic responds 200 with the access URL
     in `text/plain`).
   - Store the access URL and immediately call `GET /simplefin/accounts/…`.
6. The first call returns an empty envelope with one `errors[]` entry:
   `Sync scheduled. Data will be ready on the next call.` — this is
   expected and by design: freentonic never blocks on Chrome, it
   enqueues the sync and returns immediately.
7. Wait for the sync to complete. In the admin UI, the profile state
   cycles `idle → queued → running → ready`. A sync takes as long as the
   bank takes, typically 20–90 seconds.
8. Back in Actual, click **Sync** again. This time the `ready` state is
   hit and the envelope is returned with real transactions. Actual will
   prompt you to select which bank accounts to link.

From this point, every Actual **Sync** click triggers a fresh
`GET /simplefin/accounts/…`. Two things can happen:

- **Fresh cache exists (state = `ready`):** Actual gets the payload,
  freentonic flips the profile back to `idle`, and the transactions
  land in your ledger.
- **No cache (state = `idle`):** freentonic enqueues a sync and
  returns `Sync scheduled. Data will be ready on the next call.`
  Actual's next click returns the data.

This "two-click" dance is deliberate. Actual's UI is synchronous; bank
scraping through Chrome is slow and can't be made synchronous without
holding Actual's request open for a minute. The alternative — a
scheduler that keeps the cache warm — is covered in Step 7.

---

## Step 7 — Configure optional auto-sync

If you want Actual's first click to return data, set a `sync_interval_seconds`
on the profile. Freentonic will then run a sync in the background every
N seconds (minimum 5 minutes), so the cache is almost always warm.

### Via the admin UI

When creating the profile, fill in **Auto-sync interval** with a value
like `21600` (6 hours). You can also PATCH an existing profile later.

### Via the admin API

```sh
curl -H "Authorization: Bearer $FREENTONIC_ADMIN_PASSWORD" \
     -H "Content-Type: application/json" \
     -X PATCH \
     -d '{"sync_interval_seconds": 21600}' \
     http://127.0.0.1:7878/admin/api/profiles/ing_personal
```

### Choosing a cadence

| Cadence      | Pros                                         | Cons |
| ------------ | -------------------------------------------- | ---- |
| 6h           | Actual's Sync click almost always returns data immediately. | 4 sessions/day against the bank. |
| 24h          | Gentle on the bank; still fresh enough for weekly budgeting. | Morning sync may lag until auto-fires. |
| Off (blank)  | Only syncs when the user clicks Sync. Minimum load. | First click always returns empty + notice. |

The SimpleFIN sync worker shares the same Chrome mutex as
`/invoke`, so a busy auto-sync schedule won't cause concurrent Chrome
processes — it just queues up.

### Hiding specific bank accounts from Actual

Some banks return joint or closed accounts your provider can't filter
out. Set `hidden_accounts` on the profile:

```sh
curl -H "Authorization: Bearer $FREENTONIC_ADMIN_PASSWORD" \
     -H "Content-Type: application/json" \
     -X PATCH \
     -d '{"hidden_accounts": ["12345-joint", "99999-closed"]}' \
     http://127.0.0.1:7878/admin/api/profiles/ing_personal
```

The listed account IDs (whatever your workflow's normalizer emits as
`external_id`) are stripped from the envelope before it leaves
freentonic. Actual never sees them.

---

## Re-authentication via VNC

Banks invalidate sessions for many reasons: 90-day device-trust
expiration, rotated MFA secrets, password changes, anti-fraud
flags. When this happens:

1. A sync fails. If your workflow's `error_signals` declared a
   `kind: reauth` pattern for the "login failed / session expired"
   screen, freentonic sets the profile state to **`needs_reauth`**. In
   the admin UI the profile row turns orange and a **Re-authenticate
   (VNC)** button appears.
2. **Stop.** Freentonic won't auto-retry in `needs_reauth` — that would
   just hammer the bank with failing logins. Intervene manually.
3. Click **Re-authenticate (VNC)** in the admin UI. A headed Chrome
   launches in the container's Xvfb and the UI shows a one-shot VNC
   password (8 alphanumeric chars) plus an **Open noVNC** link. This
   password is minted fresh per headed sync and becomes invalid the
   instant the sync finishes — VNC is locked down for every other moment.
4. Click **Open noVNC**. noVNC autoconnects using the one-shot
   password. You should see the container's Xvfb desktop with Chrome
   at the bank's login page.
5. Complete the login as a human — type the password, solve whatever
   2FA the bank wants, confirm the device-trust prompt. Chrome persists
   cookies + device-trust in the named volume, so subsequent headless
   syncs will work again.
6. When the workflow finishes the login phase, the sync proceeds
   normally. The profile state returns to `ready` and Actual's next
   click picks up the data.

> **`kind: reauth` is opt-in per workflow.** If the workflow you're using
> doesn't yet declare the re-auth signal, a session-expired failure
> surfaces as a generic `error` state instead of `needs_reauth`. The
> **Re-authenticate** button still works from an `error` state — you can
> trigger a headed sync from any state by calling `POST /admin/api/profiles/:key/sync`
> with `{"headed": true}`. See
> [workflow-error-signals.md](workflow-error-signals.md#kind-reauth--distinguishing-re-authentication-from-hard-errors)
> to add the signal to your provider YAML.

---

## Running behind a reverse proxy

Exposing freentonic's admin password and bank-credential upload form
over plain HTTP is a bad idea on anything larger than your own laptop.
A minimal Caddy config that terminates TLS and fronts the container:

```caddy
freentonic.yourdomain.example {
  encode gzip zstd

  # SimpleFIN protocol + admin UI on the same vhost.
  reverse_proxy 127.0.0.1:7878

  # Optional: separate path / port for noVNC so you can reach VNC
  # without opening port 6080 to the internet. Bind it to a
  # firewalled-down subdomain + IP allowlist.
  @vnc path /vnc/* /websockify
  handle @vnc {
    basicauth {
      operator <bcrypt-hash>
    }
    reverse_proxy 127.0.0.1:6080
  }
}
```

Nginx equivalent:

```nginx
server {
  server_name freentonic.yourdomain.example;
  listen 443 ssl http2;
  ssl_certificate     /etc/letsencrypt/live/freentonic.yourdomain.example/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/freentonic.yourdomain.example/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:7878;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
  }
}
```

Once TLS is fronting freentonic, update `FREENTONIC_PUBLIC_URL`:

```sh
FREENTONIC_PUBLIC_URL=https://freentonic.yourdomain.example
```

and restart. Existing access URLs that Actual already stored keep
working; new setup tokens will embed the HTTPS URL.

> **Don't expose port 6080 (noVNC) to the public internet.** In
> SimpleFIN mode the password is minted fresh per headed sync, but the
> noVNC proxy itself has no second auth layer. Gate it behind a VPN,
> basic auth on your reverse proxy, an IP allowlist, or a LAN-only bind.

---

## Backup, rotation, and disaster recovery

### What to back up

| Path                        | What it contains                                               | Loss impact |
| --------------------------- | -------------------------------------------------------------- | ----------- |
| `~/freentonic/simplefin/`   | Encrypted bank credentials, profile metadata, state machine.   | Rebuild every profile by hand. |
| `~/.secrets/freentonic.master-key` | The AES master key. **Losing it = the backup above is permanently unreadable.** | Need to re-enter every credential. |
| `~/.secrets/freentonic.admin-password` | Admin password.                                    | Can be regenerated (restart container with a new value). |
| Docker volume `freentonic-chrome-profile` | Chrome device-trust.                           | Losing it triggers re-auth-via-VNC on every profile. |
| `~/freentonic/runs/`        | Per-sync logs + screenshots.                                   | Troubleshooting history. Safe to purge on schedule. |

### Rotating the master key

**There is no in-place re-encrypt tool in v1.** Rotation is a manual
flow:

1. Generate a new key (Step 2a).
2. For every profile, re-upload credentials through the admin UI while
   the container is still running with the **old** key — that
   round-trips them into memory and back to disk.
3. Stop the container, swap `FREENTONIC_SECRETS_KEY` for the new value,
   start it.
4. The previously re-uploaded credentials are already encrypted with
   the new key (because the Feature rebuilt them at upload time).
   Credentials that weren't touched in step 2 will fail to decrypt —
   re-upload those too.

Simpler rotation for small deployments: just re-upload every
credential after swapping the env var. The admin UI's "Save credentials"
flow always re-encrypts with the active master key.

### Losing `FREENTONIC_SECRETS_KEY`

The encrypted profile files on disk are unrecoverable. You'll need to:

1. Generate a new master key.
2. Delete (or move aside) every file in
   `~/freentonic/simplefin/profiles/` — they can't be decrypted anyway.
3. Re-create every profile through the admin UI.
4. Re-enter every credential.
5. Re-mint a setup token for each profile and re-link in Actual.

Actual's existing transaction history is unaffected; you're only
re-establishing the sync channel.

---

## Troubleshooting

### The admin UI sign-in shows "Incorrect password" every time

`FREENTONIC_ADMIN_PASSWORD` isn't set, or isn't the value you're typing.
Check the env var inside the container:

```sh
docker exec freentonic-server printenv | grep FREENTONIC_ADMIN
```

### Actual shows "Connection Invalid: re-authentication required."

The profile's state is `needs_reauth`. Go to the admin UI → click
**Re-authenticate (VNC)** and complete the login in noVNC. See
[Re-authentication via VNC](#re-authentication-via-vnc).

### Actual pastes the setup token but gets "claim expired"

The 10-minute TTL has passed, or the claim was already exchanged.
In the admin UI → click **Setup token** again and paste the new one.

### `GET /simplefin/accounts/…` always returns empty with "Sync scheduled"

Either the very first call (expected — click Sync again), or the sync
is failing silently. Check:

```sh
curl -s -H "Authorization: Bearer $FREENTONIC_ADMIN_PASSWORD" \
     http://127.0.0.1:7878/admin/api/profiles/ing_personal/runs | jq
```

Then click **Runs** on the profile row in the admin UI and expand the
log of the most recent run. Common causes:

- Workflow YAML references a secret name the admin form didn't include.
- Bank has changed a selector the workflow depended on.
- Chrome crashed — often a memory issue. Increase `--shm-size`.

### noVNC connects but I see a black screen

Xvfb is running but Chrome didn't start. This happens when freentonic
is between invokes — there's nothing to display. Trigger a sync
(click **Sync now** in the admin UI) and watch the window come to life
a couple of seconds later.

### Freentonic seems to process one sync at a time even with many profiles

It does — by design. One Chrome per container (the `@invoke_mutex`
invariant). If you need concurrency, run multiple containers with
different `FREENTONIC_PUBLIC_URL` and different admin passwords.

### The container eats memory over time

Chrome leaks memory across long-lived profiles. Mitigations:

- Set `--restart unless-stopped` and a cron that `docker restart
  freentonic-server` weekly. The in-memory sync queue is ephemeral;
  any auto-sync schedule resumes on its next tick.
- Increase `--shm-size=512m` if OOM-killed Chrome is the symptom.

### Port 7878 is already in use

Change the host port:

```sh
export FREENTONIC_LISTEN_PORT=17878
./docker-run-freentonic.sh server
```

Update `FREENTONIC_PUBLIC_URL` to match.

---

## Reference: environment variables

**Required when `FREENTONIC_SIMPLEFIN_ENABLED=1`:**

| Name                         | Purpose |
| ---------------------------- | ------- |
| `FREENTONIC_SECRETS_KEY`     | 32-byte base64 master key. Derives per-profile AES subkeys. |
| `FREENTONIC_ADMIN_PASSWORD`  | Admin UI + admin API bearer. |
| `FREENTONIC_PUBLIC_URL`      | URL actual-server will reach. Embedded in setup tokens. No trailing slash. |

**Optional SimpleFIN settings:**

| Name                          | Default                   | Purpose |
| ----------------------------- | ------------------------- | ------- |
| `FREENTONIC_SIMPLEFIN_ENABLED`| `0`                       | Master toggle. `1` enables all `/simplefin/*` + `/admin/*` routes. |
| `FREENTONIC_SIMPLEFIN_DIR`    | `$(pwd)/freentonic-simplefin` | Host path bind-mounted at `/workspace/simplefin`. |
| `FREENTONIC_SIMPLEFIN_ROOT`   | `/workspace/simplefin`    | Container-side state root. Rarely changed. |

**Inherited from the base invoke server (still relevant):**

| Name                          | Purpose |
| ----------------------------- | ------- |
| `FREENTONIC_INVOKE_TOKEN`     | Bearer for `/invoke`. Separate from admin password. |
| `FREENTONIC_WORKFLOWS_DIR`    | Where workflow YAMLs live. |
| `FREENTONIC_RUNS_DIR`         | Where per-run logs land. |
| `FREENTONIC_VNC`              | `1` enables Xvfb + x11vnc + noVNC. Required for `Re-authenticate (VNC)`. |
| `FREENTONIC_LISTEN_PORT`      | Host-side port (default 7878). |
| `FREENTONIC_CHROME_PROFILE_VOLUME` | Named volume for Chrome device-trust. |

---

## Reference: admin REST API

All `/admin/api/*` endpoints authenticate via `Authorization: Bearer
$FREENTONIC_ADMIN_PASSWORD`, or via the session cookie set by
`/admin/login` when you use the UI.

| Method | Path                                                    | Purpose |
| ------ | ------------------------------------------------------- | ------- |
| GET    | `/admin/api/status`                                     | Summary of all profiles + their current state. Used by the UI's 2s poll. |
| GET    | `/admin/api/metrics`                                    | Aggregate counts (profiles by state, runs in the last 24h, queue depth, age distribution). |
| GET    | `/admin/api/workflows`                                  | List available workflow YAMLs + their declared secrets. |
| GET    | `/admin/api/profiles`                                   | List profile summaries. |
| POST   | `/admin/api/profiles`                                   | Create a profile. Body: `{profile_key, workflow, display_name?, lookback_days?, max_lookback_days?, sync_interval_seconds?, hidden_accounts?}`. |
| GET    | `/admin/api/profiles/:key`                              | One profile summary. |
| PATCH  | `/admin/api/profiles/:key`                              | Update `display_name`, `workflow`, `lookback_days`, `max_lookback_days`, `sync_interval_seconds`, `hidden_accounts`. |
| DELETE | `/admin/api/profiles/:key`                              | Delete. Also unlinks the cached payload. Chrome profile directory is **not** deleted (re-create the profile with the same key to reuse device-trust). |
| POST   | `/admin/api/profiles/:key/credentials`                  | Body: `{secrets: {NAME: "value", ...}}`. Re-encrypts under the active master key. |
| POST   | `/admin/api/profiles/:key/sync`                         | Enqueue a sync. Body: `{headed: bool}` — `true` spawns Chrome visibly so you can watch via noVNC. |
| POST   | `/admin/api/profiles/:key/setup-token`                  | Mint a one-shot claim URL. 10-minute TTL. |
| POST   | `/admin/api/profiles/:key/rotate-access-url`            | Invalidate the current access URL. User must re-claim with a new setup token. |
| GET    | `/admin/api/profiles/:key/runs`                         | Last 20 runs. |
| GET    | `/admin/api/profiles/:key/runs/:run_id/log`             | Last 256 KiB of the child freentonic log for a run. |

All responses are JSON. Charset-validated path components.
`404` on missing profile; `400` on malformed body; `401` on bad bearer.

### Example — scripting a full provision

```sh
TOKEN="$FREENTONIC_ADMIN_PASSWORD"
BASE="http://127.0.0.1:7878/admin/api"

# Create.
curl -s -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -X POST "$BASE/profiles" \
     -d '{"profile_key":"ing_personal","workflow":"ing/workflow.yml","lookback_days":30,"sync_interval_seconds":21600}'

# Upload credentials from a file that already has them in KEY=value form.
creds_json=$(python3 -c '
import sys, json
pairs = dict(line.strip().split("=", 1) for line in open("/tmp/ing.env") if "=" in line)
print(json.dumps({"secrets": pairs}))
')
curl -s -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -X POST "$BASE/profiles/ing_personal/credentials" \
     -d "$creds_json"

# Mint a setup token to paste into Actual.
curl -s -H "Authorization: Bearer $TOKEN" \
     -X POST "$BASE/profiles/ing_personal/setup-token" | jq -r .setup_token
```

---

## See also

- [invoke-server-deployment.md](invoke-server-deployment.md) — the
  non-SimpleFIN path. Useful if your web app also talks `/invoke` directly.
- [invoke-server-api.md](invoke-server-api.md) — `/invoke` request/response reference.
- [workflow-error-signals.md](workflow-error-signals.md) — how to add
  `kind: reauth` to a provider YAML.
- [running-in-docker.md](running-in-docker.md) — single-shot CLI mode
  (useful for developing new providers before exposing them through
  the SimpleFIN bridge).
- [writing-plugins.md](writing-plugins.md) — authoring your own provider.
- [SECURITY.md](../SECURITY.md) — threat model + invariants.
