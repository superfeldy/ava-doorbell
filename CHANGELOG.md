# Changelog

## [4.4] - 2026-03-27

### Streaming
- Default protocol order changed to WebRTC-first (was MSE-first) — eliminates 15s MSE timeout delay, connections now under 1s
- Connection generation counter prevents resource leaks during rapid layout switches — stale WebRTC/MSE connections are detected and cleaned up immediately
- Cache busters bumped to v4.12 across all JS/CSS imports and HTML template

### Talk Relay DSP
- Gate fade-in ramp (5ms / 40 samples) on silence→speech transitions prevents speaker clicks
- AGC gain capped to 8x on gate-open (was uncapped at up to 50x, causing loud first-chunk pop after silence)
- RTP marker bit set on first packet after silence (RFC 3551 talkburst signaling)

### Android
- Doorbell overlay wakes screen via SCREEN_BRIGHT_WAKE_LOCK with ACQUIRE_CAUSES_WAKEUP (was no-op on API 27+ due to deprecated FLAG_TURN_SCREEN_ON)
- Overlay auto-dismiss timer resets correctly on rapid ring events (was race where earliest callback killed the service prematurely)

## [4.3] - 2026-03-13

### Android UX
- Loading overlay shows elapsed time ("Connecting... 5s") with network warning after 15s
- Status dot enlarged (14dp) with "MQTT" label, pulses on connection loss
- Mic FAB shows specific error reasons (permission denied, relay not responding, connection lost)
- Swipe hint shown on first 3 launches (not just first); includes "Hold 3s for settings" hint
- MJPEG-only mode badge ("MJPEG" indicator) when WebView is bypassed
- Overlay preview shows "Preview unavailable" text after 10 failed polling attempts
- WebView long-click disabled to prevent text selection during gestures
- Swipe cycling fetches server config and skips layouts with no cameras assigned
- WebView recreation clears clients to prevent memory leaks
- Loading timer uses active flag to prevent self-posting loop after dismissal
- MJPEG frame URLs include cache-buster timestamp
- Handler callbacks (layout indicator, loading timer, swipe hints) cleaned up in onDestroy
- AudioRecord validates buffer size before starting recording
- Exit button (✕) on main screen top-left corner for quick return to home screen
- Exit to Home Screen button also available in Settings (with confirmation dialog)
- Auto-start on boot via BOOT_COMPLETED receiver (dedicated kiosk hardware)

### Multiview Web
- Live countdown timer on reconnect overlay (counts down from delay)
- Talk button shows specific error toasts (mic denied, relay unreachable)
- Mute state preserved across layout switches
- Empty layouts skipped when cycling
- Double-tap fullscreen debounced (300ms threshold)
- Fullscreen toggle blocked when reconnect/loading overlay is showing
- Auto-retry after 60s when max reconnect attempts reached (wall-mounted recovery)
- Layout name toast on switch ("Single", "2-up", etc.)
- postMessage handler validates origin to prevent cross-origin hijacking
- Init failure shows error banner with Retry button (replaces blank screen)
- Fullscreen and controls init guards prevent duplicate event listeners
- MSE isTypeSupported wrapped in safety check for older WebViews
- Fixed querySelector syntax error in countdown timer text update

### Backend
- Session timeout enforced server-side (constant, not stored in client cookie)
- Config save endpoint strips protected keys before merge with warning log
- talk_relay audio send uses run_in_executor to avoid blocking the event loop
- WebSocket proxy uses async context manager for guaranteed ClientSession cleanup
- Fixed _restart_service return type hint (bool → Union[bool, dict])
- Replaced inline __import__("time") with proper module import
- Talk relay AGC tuned for doorbell speaker: float gain precision, removed soft limiter, fast attack (0.01) for feedback reduction, min gain 2x / max 50x / target 32000

## [4.1] - 2026-03-02

### Fixed
- Swipe gesture detection: added VelocityTracker for velocity-based recognition, diagonal rejection (horizontal must exceed 2x vertical), ACTION_CANCEL handling to prevent lost swipes, and 400 px/sec minimum velocity threshold
- Rate limit lockout: correct password now clears rate limit after fat-finger lockout
- Empty camera name validation: rejected at model level (min_length=1)
- XSS in camera name: HTML tags stripped on create/update, ID slug sanitized
- go2rtc restart cooldown: 30s cooldown applied to individual restart endpoint (was only on restart-all)
- Config restore error handling: bad JSON returns 400 instead of 500
- Negative log lines: `ge=1` constraint on lines parameter
- Android URL injection: `Uri.encode()` applied to defaultCamera in all URL builders
- Android camera name validation: alphanumeric + hyphens/underscores only

### Added
- `deploy.sh` — push updates from Mac to Pi via SSH/rsync
- `update.sh` — pull updates from GitHub on Pi
- `log_tail.sh` — stream Pi service logs remotely
- `/api/logs/download` endpoint for log file export
- Tailscale remote access documentation in SETUP.md

### Infrastructure
- GitHub Release v4.1 with APK artifact
- Deploy key support for Pi-side git pull

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
