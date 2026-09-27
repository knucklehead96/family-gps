# Family GPS

Private family location sharing on a Raspberry Pi. All data stays on your machine.

- **Phones:** only the [OwnTracks](https://owntracks.org) app. No VPN, low battery use.
- **Server:** OwnTracks Recorder, a web map, ntfy alerts and Tailscale, all in Docker.
- **Alerts:** "Alice arrived at School" / "Bob left Home" through the ntfy app.
- **Portable:** one `curl` command to install; one backup file to move servers.

```
phones ──HTTPS /pub──▶ Tailscale Funnel ──▶ Pi: caddy ─▶ recorder ─▶ data/store
                                              └──────▶ ntfy (alerts)
you (tailnet) ──▶ https://mrn-pi.<tailnet>.ts.net:8443 ─▶ map + history
```

## 1. One-time Tailscale setup

In the [admin console](https://login.tailscale.com/admin):

1. **DNS:** enable **MagicDNS** and **HTTPS Certificates**.
2. **Access controls:** allow **Funnel**. The console offers to add the `funnel` node attribute; accept it.
3. **Settings → Keys:** generate an **auth key** (not reusable, not ephemeral, no tags).

## 2. Install on the Pi

Raspberry Pi OS Lite 64-bit (or any Debian/Ubuntu):

```bash
curl -fsSL https://raw.githubusercontent.com/knucklehead96/family-gps/main/install.sh | sudo bash -s -- --authkey tskey-auth-XXXX
```

The installer:
- installs Docker if it's missing
- downloads the container images (a few minutes on a Pi)
- starts everything

Then add each family phone with `fgps add <name>`.

Afterwards, in the Tailscale admin console, open the `mrn-pi` machine and choose **Disable key expiry**.

## 3. Phones

Run `fgps add <name>` (or answer the installer prompt), then on that phone:

1. Install **OwnTracks**.
2. Scan the QR code and open it in OwnTracks.
3. Allow location **Always** / **Allow all the time**, and exempt OwnTracks from battery optimisation.

The QR code applies low-battery settings:
- significant-change mode
- OS geofences
- HTTP (no open connection)

Everyone sees everyone on the OwnTracks map.

## 4. Places and alerts

```bash
fgps place add "Home" 12.97160 77.59460        # lat lon [radius, default 150 m]
fgps place add "School" 12.93000 77.61000 200
fgps qr alice                                  # re-scan on each phone to load the places
fgps notify add mrn                            # prints ntfy app login for whoever gets alerts
```

Get coordinates by long-pressing a spot in Google Maps.

The phone's OS detects arrive and leave events, which is cheap on battery, and the Pi sends the alert.

**iOS alerts:** instant delivery on iOS goes through Apple push, relayed by ntfy.sh. Only a hashed message ID leaves the Pi, and the alert text is fetched from your server.

## 5. Moving servers

```bash
# old server
fgps uninstall                 # backs up to ./family-gps-backup-*.tgz, then removes everything
# copy the .tgz to the new server, then:
curl -fsSL https://raw.githubusercontent.com/knucklehead96/family-gps/main/install.sh \
  | sudo bash -s -- --restore ./family-gps-backup-XXXX.tgz
```

The backup carries the server's Tailscale identity, so the URL stays the same and **phones need no changes**. Never run the same backup on two servers at once.

## Commands

```
fgps add|remove <name>        family phones
fgps list                     last seen, battery
fgps qr <name> [--file]       setup QR code again (or a .otrc file to send)
fgps place add|remove|list    geofences
fgps notify add|remove|list   who gets alerts
fgps status | logs [svc]      health
fgps backup | restore <file>  data
fgps update | uninstall
```

## URLs

| URL | Who | Access |
|---|---|---|
| `https://mrn-pi.<tailnet>.ts.net/pub` | phones | public, per-person password |
| `https://mrn-pi.<tailnet>.ts.net` | ntfy app | public, ntfy login |
| `https://mrn-pi.<tailnet>.ts.net:8443` | you, on your tailnet | map and history |

## Layout

Everything lives in `/opt/family-gps`. Only `data/` and `.env` matter; the rest is re-downloaded.

```
data/store      locations (OwnTracks Recorder)
data/tailscale  server identity
data/ntfy       alert users and cache
data/secrets    phone passwords (for re-showing QR codes)
data/places.json
```
