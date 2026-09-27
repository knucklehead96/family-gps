# Family GPS

Private family location sharing on your own machine (Raspberry Pi, mini PC, any Linux box with Docker). No cloud service stores your data.

- **Phones:** only the [OwnTracks](https://owntracks.org) app. No VPN, low battery use.
- **Server:** OwnTracks Recorder, a web map, [ntfy](https://ntfy.sh) alerts and [Tailscale](https://tailscale.com), all in Docker.
- **Alerts:** "Alice arrived at School" / "Bob left Home" in the ntfy app.
- **Portable:** one `curl` command to install; one backup file to move to another server with the same URL.

```
phones ──HTTPS /pub──▶ Tailscale Funnel ──▶ server: caddy ─▶ recorder ─▶ data/store
                                               └──────▶ ntfy (alerts)
you (on your tailnet) ──▶ https://<hostname>.<tailnet>.ts.net:8443 ─▶ map + history
```

In the commands below:
- `<github-user>` is the GitHub account hosting this repo (fork it and use yours)
- `<hostname>` is the server name you choose (default `family-gps`)
- `<tailnet>` is your tailnet's DNS name (admin console → DNS, for example `tail1a2b3c`)

## 1. Tailscale setup (once)

In the [Tailscale admin console](https://login.tailscale.com/admin):

1. **DNS:** enable **MagicDNS**, and under **HTTPS Certificates** click **Enable HTTPS**. Funnel does not start without it.
2. **Access controls → JSON editor:** make sure the policy grants Funnel. Newer tailnets have it already. If `funnel` isn't there, add:
   ```json
   "nodeAttrs": [
     { "target": ["autogroup:member"], "attr": ["funnel"] },
   ],
   ```
3. **Settings → Keys:** generate an **auth key** (not reusable, not ephemeral, no tags). It's used once.

## 2. Install

On the server (Raspberry Pi OS 64-bit, Debian or Ubuntu):

```bash
curl -fsSL https://raw.githubusercontent.com/<github-user>/family-gps/main/install.sh \
  | sudo bash -s -- --authkey tskey-auth-XXXX --hostname <hostname>
```

The installer:
- installs Docker if needed
- downloads the images (a few minutes on a Pi)
- starts everything
- checks that the public URL works

It ends by printing your URLs.

Then, in the admin console, open the new machine and choose **Disable key expiry**. Otherwise Funnel stops after 180 days.

## 3. Add family phones

For each person:

```bash
fgps add <name>          # lowercase, e.g. alice; shows a QR code
```

On that person's phone:
1. Install **OwnTracks** (App Store / Google Play).
2. Scan the QR code and open it in OwnTracks.
3. Allow location **Always** (Android: **Allow all the time**) and turn off battery optimisation for OwnTracks.

Check with `fgps list`: the phone should appear within a few minutes. Everyone sees everyone on the OwnTracks map.

The QR code applies low-battery settings:
- significant-change mode
- OS geofences
- HTTP (no open connection)

## 4. Places and alerts

```bash
fgps place add "Home" 12.97160 77.59460        # lat lon [radius m, default 150]
fgps place add "School" 12.93000 77.61000 200
fgps notify add <name>                         # prints an ntfy app login for whoever gets alerts
fgps qr <name>                                 # re-scan on each phone to load new places
```

Get coordinates by long-pressing a spot in Google Maps.

The phone's OS detects arrive and leave events, which costs very little battery, and the server sends the alert.

**iOS:** instant ntfy delivery goes through Apple push, relayed by ntfy.sh. Only a hashed message ID leaves your server; the alert text is fetched from it.

## 5. Moving to a new server

The backup contains the server's **Tailscale identity**, so the new server gets the **same URL**. Phones need no changes, and you need no new auth key.

**On the old server:**

```bash
cd ~
fgps uninstall            # backs up to ~/family-gps-backup-<date>.tgz, then removes everything
```

To keep the old server as a fallback instead, run `fgps backup` then `fgps stop`.

**Copy the backup to the new server:**

```bash
scp ~/family-gps-backup-*.tgz <user>@<new-server>:~
```

**On the new server:**

```bash
cd ~
curl -fsSL https://raw.githubusercontent.com/<github-user>/family-gps/main/install.sh \
  | sudo bash -s -- --restore ~/family-gps-backup-XXXX.tgz
fgps status               # should show "Funnel on"
fgps list                 # phones should appear again as they report
```

Phones store their points while the server is down and upload them when it's back, so no history is lost.

**Rules when moving:**
- **Never run the same backup on two servers at once.** They share one Tailscale identity and will fight over it. Stop or uninstall the old one first.
- The backup holds every password and the Tailscale identity. Keep it private and delete spare copies.
- The new server can be a different kind of machine (Pi → x86 mini PC); the images support both.

## Everyday commands

```
fgps add|remove <name>          family phones
fgps list                       last seen, battery
fgps qr <name> [--file]         setup QR code again (or a .otrc file to send)
fgps place add|remove|list      geofences
fgps notify add|remove|list     who gets alerts
fgps status | logs [service]    health, URLs, Funnel state
fgps start | stop | restart     services (data is kept)
fgps backup | restore <file>    one-file backup of everything
fgps update                     latest version from GitHub (keeps data)
fgps uninstall                  backup, then remove everything
```

## URLs

| URL | Who | Access |
|---|---|---|
| `https://<hostname>.<tailnet>.ts.net/pub` | phones | public, per-person password |
| `https://<hostname>.<tailnet>.ts.net` | ntfy app | public, ntfy login |
| `https://<hostname>.<tailnet>.ts.net:8443` | you, on your tailnet | map and history |

The hostname becomes publicly discoverable, because all HTTPS certificates are logged publicly. Everything behind it is password-protected, but pick a name that doesn't reveal much.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Installer warns `/pub not reachable (got '000')` | HTTPS certificates or the Funnel policy are missing (step 1). Fix them, then run `fgps restart`. |
| `fgps status` shows "No serve config" | Same as above. |
| `fgps: command not found` | The installer didn't finish. Re-run it (keeps data). |
| Tailscale never comes up | The auth key is used or expired. Generate a new one and re-run the installer. |
| Phone doesn't appear in `fgps list` | Check location is set to **Always** and battery optimisation is off; in OwnTracks, tap the upload icon to send now. |
| `/pub` returns 403 | No family members yet: `fgps add <name>`. |

## Files

Everything lives in `/opt/family-gps`. Only `data/` and `.env` matter; the rest is re-downloaded by `fgps update`.

```
data/store        locations (OwnTracks Recorder)
data/tailscale    server identity (keeps the URL when moving)
data/ntfy         alert logins and cache
data/secrets      phone passwords (to re-show QR codes)
data/places.json  geofences
.env              hostname, timezone, alert token
```
