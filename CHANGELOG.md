# Changelog

## [4.0] - 2026-02-24

### Added
- FastAPI admin dashboard with setup wizard (replaces Flask from v3)
- go2rtc integration for WebRTC/MSE/RTSP camera streaming
- WebSocket proxy (`/api/ws-proxy`) for cross-origin go2rtc access
- NativeTalkManager — native Android mic capture via OkHttp WebSocket (bypasses WebView getUserMedia limitation)
- DoorbellOverlayService — floating popup on ring events with chime audio
- Two-way audio pipeline: smoothing, noise gate, AGC, soft limiter, G.711A encoding
- Backchannel auto-recovery with exponential backoff (2s → 4s → 8s → 16s → 30s)
- go2rtc stream reset at retry #3 to unstick doorbell RTSP
- WebSocket status messages (connecting/ready/failed/unavailable) from talk relay to Android
- MediaTek auto-detection — forces MJPEG-only mode on incompatible chipsets
- Multi-view camera layouts (single, 2-up, 4-up, 6-up, 8-up, 9-up)
- Auto-cycle between layout presets on a timer
- Camera discovery via network scanning
- NVR channel auto-detection
- EncryptedSharedPreferences for API token storage
- Atomic config writes with in-memory cache
- MQTT-based event pipeline (alarm_scanner → mosquitto → Android)
- Ring cooldown (10s default) to prevent duplicate notifications
- SSL/TLS companion server on port 5443
- Samba file sharing (config, services, recordings)
- Config backup/restore via admin API
- Burn-in test script (`burn_in.sh`)
- Integration test suite (`integration_test.sh`)

### Security
- Command injection whitelist on service management endpoints
- WebSocket max_size (64KB) to prevent DoS
- Protected config keys (admin, version, setup_complete) blocked from API writes
- Session signing with persistent secret
- API token authentication with secure hash comparison
- ProGuard rules with Tink crypto keep rules

### Fixed
- CORS origin reverted to `"*"` for WebView compatibility
- WebSocket proxy try-except for clean disconnect handling
- SeekBar brightness max fixed (100, not 255)
- MQTT race condition with synchronized connectionLock
- ClientSession leak in async HTTP calls
- Deprecated Paho MQTT callback API updated to v2

### Infrastructure
- Systemd services with crash-loop protection (StartLimitBurst=5/60s)
- journald log rotation (100MB cap, 2-week retention)
- Daily config backup cron (14-day rotation)
- GitHub release with APK artifact
