# Contributing

## Development Setup

### Pi Services (Python)

```bash
# Clone and set up venv
git clone https://github.com/superfeldy/ava-doorbell.git
cd ava-doorbell
python3 -m venv venv
source venv/bin/activate
pip install -r services/requirements.txt

# Syntax check
python3 -m py_compile services/talk_relay.py
python3 -m py_compile services/alarm_scanner.py
python3 -m py_compile services/admin/main.py
```

### Android App (Kotlin)

```bash
cd android-app
./gradlew assembleDebug
# APK: app/build/outputs/apk/debug/app-debug.apk
```

Requires JDK 17+ and Android SDK (API 35).

## Project Layout

| Directory | Language | What it does |
|-----------|----------|-------------|
| `services/admin/` | Python (FastAPI) | Admin dashboard, REST API, go2rtc proxy |
| `services/talk_relay.py` | Python | Mic audio relay to doorbell RTSP backchannel |
| `services/alarm_scanner.py` | Python | Doorbell event polling and MQTT publishing |
| `android-app/` | Kotlin | Kiosk camera viewer with talk and ring overlay |
| `services/admin/static/` | JS/CSS/HTML | Frontend assets |

## Commit Messages

Use imperative mood in the subject line:

```
Add backchannel retry with exponential backoff
Fix MQTT race condition in MqttManager
Update config cache to invalidate on write
```

Keep subjects under 72 characters. Use the body for the "why".

## Testing

```bash
# Integration tests (requires Pi + doorbell on network)
./integration_test.sh

# Burn-in soak test
./burn_in.sh
```

## Code Style

- **Python**: PEP 8, 4-space indent
- **Kotlin**: Android/Kotlin conventions, 4-space indent
- **JavaScript**: 2-space indent
- **Config**: `.editorconfig` enforces these automatically
