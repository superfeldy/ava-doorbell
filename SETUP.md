# AVA Doorbell v4.0 — Setup Guide

## Quick Start

```bash
ssh vact@ava-doorbell.local
cd ~/ava-doorbell-v4
chmod +x setup.sh
./setup.sh
```

The interactive script walks you through everything: site info, connectivity checks, software install, camera discovery, and verification. Follow the prompts.

---

## What setup.sh Does

| Step | What Happens |
|------|-------------|
| 1. Gather Site Info | Prompts for Pi IP, doorbell IP/creds, NVR IP/creds, admin password |
| 2. Pre-flight Checks | Pings devices, verifies doorbell credentials via Dahua HTTP API |
| 3. Install Software | Runs install.sh (mosquitto, go2rtc, Python services, Samba) |
| 4. Verify Services | Checks all 6 systemd services are running, offers restart |
| 5. Configure System | Sets admin password, generates SSL cert, discovers cameras via API |
| 6. Verify Everything | Tests admin dashboard, go2rtc streams, MQTT broker, doorbell API |
| 7. Done | Prints dashboard URL, Android app settings, and verification checklist |

---

## Before You Start (Pi Preparation)

Skip these if the Pi is already set up and reachable via SSH.

1. **Flash SD card** — Raspberry Pi Imager → Pi OS 64-bit Bookworm Lite
   - Hostname: `ava-doorbell`, SSH enabled, user: `vact`
2. **Set static IP** — `sudo nmtui` → set to `10.10.10.167` (or use DHCP reservation)
3. **Transfer files** from your Mac:
   ```bash
   rsync -avz --exclude='android-app' --exclude='.DS_Store' --exclude='__pycache__' \
     /path/to/ava-doorbell-v4/ vact@10.10.10.167:~/ava-doorbell-v4/
   ```

Then run `./setup.sh` as shown above.

---

## Manual Setup (Without setup.sh)

If you prefer the browser-based wizard instead of the script:

1. Run `./install.sh` to install software
2. Open `http://<PI_IP>:5000/setup` in a browser
3. The wizard walks through: admin password → network/SSL → camera discovery
4. After setup, log in at `http://<PI_IP>:5000` to manage cameras and layouts

---

## Android App Deployment

### Install the APK

**Option A — Download from the Pi (easiest):**
On the Android tablet's browser, navigate to:
```
http://<PI_IP>:5000/app/download
```
This downloads `ava-doorbell.apk` directly. Open the downloaded file to install.
You may need to enable "Install from unknown sources" in Android Settings → Security.

**Option B — ADB sideload:**
From a laptop with ADB installed and the tablet connected via USB:
```bash
adb install /path/to/ava-doorbell-v4/apk/ava-doorbell.apk
```
Or over WiFi (tablet and laptop on same network):
```bash
adb connect <TABLET_IP>:5555
adb install /path/to/ava-doorbell-v4/apk/ava-doorbell.apk
```

### Configure the App

Long-press (3 sec) anywhere on screen to open Settings. On first 3 launches, a swipe hint and "Hold 3s for settings" tip appear automatically.

| Setting | Value |
|---------|-------|
| Server IP | `10.10.10.167` (your Pi IP) |
| Admin Port | `5000` |
| MQTT Port | `1883` |
| Talk Port | `5001` |
| API Token | (generate in dashboard: Settings → API Token → Generate) |
| Default Camera | `doorbell_direct` |
| Default Layout | `single` |

Two-way audio: tap the mic FAB (bottom-right) to talk through the doorbell.

---

## Network Reference

### Devices

| Device | IP | Credentials |
|--------|------|------------|
| Raspberry Pi | 10.10.10.167 | vact / (your password) |
| Doorbell (VTO) | 10.10.10.187 | admin / (your password) |
| NVR | 10.10.10.195 | admin / (your password) |

### Ports

| Service | Port | Notes |
|---------|------|-------|
| Admin Dashboard | 5000 (HTTP), 5443 (HTTPS) | Web UI + API + go2rtc proxy |
| go2rtc | 1984 (HTTP), 1985 (HTTPS) | Stream status, WebSocket signaling |
| WebRTC | 8555 (UDP) | Direct video to browser |
| RTSP (go2rtc) | 8554 | Re-published streams |
| Talk Relay | 5001 (WebSocket) | Mic audio to doorbell |
| MQTT | 1883 (TCP) | Anonymous, LAN-only |
| Doorbell RTSP | 554 | Direct camera stream |
| SMB | 445 | File sharing |

### File Locations

```
~/ava-doorbell/
  config/
    config.json          Main config (cameras, credentials, layouts)
    go2rtc.yaml          Auto-generated — do not edit manually
    ssl/                 Auto-generated SSL cert + key
  services/
    alarm_scanner.py     Dahua event poller → MQTT
    talk_relay.py        WebSocket → RTSP backchannel audio
    admin/               FastAPI dashboard + routers
  bin/
    go2rtc               Streaming server binary
  venv/                  Python virtual environment
```

---

## Useful Commands

```bash
# Service management
sudo systemctl status ava-admin
sudo systemctl restart alarm-scanner
sudo journalctl -u ava-admin -f           # tail logs live

# Health checks
curl -s http://localhost:5000/api/health | python3 -m json.tool
curl -s http://localhost:1984/api/streams | python3 -m json.tool

# MQTT test (two terminals)
mosquitto_sub -t "doorbell/#" -v           # terminal 1: listen
mosquitto_pub -t "doorbell/ring" -m test   # terminal 2: trigger
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Service won't start | `sudo journalctl -u <service> -n 50 --no-pager` |
| ava-admin import error | `~/ava-doorbell/venv/bin/pip install -r ~/ava-doorbell/services/requirements.txt` |
| go2rtc port conflict | `sudo lsof -i :1984` |
| No video in browser | `curl http://localhost:1984/api/streams` — if empty, cameras not configured |
| No video on Android | Check Server IP + Admin Port in app settings; app falls back to MJPEG on MediaTek |
| No ring notifications | Check alarm-scanner: `sudo systemctl status alarm-scanner` |
| Two-way audio broken | Check talk relay: `sudo systemctl status ava-talk`, ensure Talk Port = 5001. Mic FAB now shows specific error (permission, relay, connection) |
| Loading stuck on "Connecting..." | After 15s the overlay shows "Still connecting — check network". Verify Pi is reachable and ava-admin is running |
| "MJPEG" badge on screen | Normal on MediaTek devices — WebView is bypassed, using MJPEG fallback. Auto-retries RTSP every 5 min |
| SSL warnings | Self-signed cert — click Advanced → Proceed. Regenerates on ava-admin restart if IP changes |
| Doorbell unreachable | `curl -u admin:PASSWORD http://DOORBELL_IP/cgi-bin/magicBox.cgi?action=getDeviceType` |

---

## Remote Access (Tailscale)

Access the Pi from anywhere — not just the local LAN.

### Install Tailscale

On the Pi:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Follow the printed URL to authenticate. The Pi gets a stable Tailscale IP (100.x.y.z).

On your Mac/phone: install Tailscale from https://tailscale.com/download and join the same tailnet.

### Access via Tailscale

| What | Command |
|------|---------|
| Dashboard | `http://<tailscale-ip>:5000` |
| SSH | `ssh pi@<tailscale-ip>` |
| Deploy | `PI_HOST=<tailscale-ip> bash deploy.sh` |
| Tests | `PI_HOST=<tailscale-ip> AVA_PASSWORD=<pass> bash integration_test.sh` |
| Log tail | `PI_HOST=<tailscale-ip> bash log_tail.sh` |

### Magic DNS (optional)

Enable Magic DNS in the [Tailscale admin console](https://login.tailscale.com/admin/dns). Then use the Pi's hostname instead of IP:
```
http://ava-doorbell:5000
ssh pi@ava-doorbell
```

### Tailscale SSH (optional)

Eliminates the need for SSH keys/passwords:
```bash
sudo tailscale up --ssh
```

---

## Deployment Scripts

### deploy.sh — Push from Mac

Push local changes to the Pi:
```bash
bash deploy.sh                     # sync services + restart
bash deploy.sh --build-apk         # also build and deploy APK
bash deploy.sh --dry-run           # show what would change
bash deploy.sh --skip-restart      # sync only
PI_HOST=100.x.y.z bash deploy.sh   # via Tailscale
```

### update.sh — Pull from GitHub on Pi

One-time setup (deploy key):
```bash
# On the Pi:
ssh-keygen -t ed25519 -C "ava-pi-deploy" -f ~/.ssh/ava_deploy -N ""
cat ~/.ssh/ava_deploy.pub
# Add this key to GitHub: repo Settings → Deploy keys → Add (read-only)

GIT_SSH_COMMAND="ssh -i ~/.ssh/ava_deploy" \
  git clone git@github.com:superfeldy/ava-doorbell.git ~/ava-doorbell-repo
git -C ~/ava-doorbell-repo config core.sshCommand "ssh -i ~/.ssh/ava_deploy"
```

Then to update:
```bash
bash ~/ava-doorbell-repo/update.sh
```

### log_tail.sh — Stream logs remotely

```bash
bash log_tail.sh                   # all services
bash log_tail.sh ava-admin         # single service
PI_HOST=100.x.y.z bash log_tail.sh # via Tailscale
```

### Log download via dashboard

Download logs as a file from the admin API:
```
http://<PI_IP>:5000/api/logs/download?service=ava-admin&since=1%20hour%20ago
```

---

## Security Notes

### What's Protected
- **Login**: Rate-limited to 5 wrong attempts per 15 minutes per IP. Correct password always works (clears lockout).
- **API endpoints**: All management endpoints require session or API token auth. Public endpoints: `/view`, `/api/health`, `/app/download`.
- **Config keys**: `admin`, `version`, `setup_complete` are automatically stripped from API writes (with warning log).
- **Session timeout**: Enforced server-side (60 min). Clients cannot extend their own session.
- **Frontend origin validation**: postMessage handler rejects cross-origin commands to prevent camera hijacking.
- **Camera names**: HTML tags stripped on create/update. IDs are slug-sanitized (alphanumeric + underscore only).
- **Service restarts**: go2rtc has 30s cooldown, other services 10s cooldown, systemd has crash-loop protection.
- **Restore endpoint**: Invalid JSON returns 400 (not 500). Existing admin block preserved on restore.
- **Log API**: `lines` constrained to 1-500, `service` whitelist-only, `since` regex-validated.
- **Android app**: Camera name validated (alphanumeric/hyphens/underscores), URLs use `Uri.encode()`.

### What's Not Protected (by design)
- **go2rtc API** (port 1984): No authentication — streams are accessible to anyone on the network. This is standard for go2rtc.
- **MQTT** (port 1883): Anonymous access, LAN-only. Anyone on the network can publish/subscribe.
- **HTTP** (port 5000): Unencrypted. Use Tailscale for remote access (encrypted tunnel).

### Recommendations
- Use Tailscale for all remote access (never port-forward 5000/1984/1883 to the internet)
- Change the default admin password during setup
- Use the admin dashboard to generate a unique API token for the Android app

---

## Upgrading from v3

1. Stop v3 services: `sudo systemctl stop ava-admin alarm-scanner ava-talk`
2. Transfer v4 files to the Pi
3. Run `./setup.sh` — it runs install.sh (preserves existing config.json) and reconfigures
4. If `setup_complete` is already true, Step 5 is skipped automatically
