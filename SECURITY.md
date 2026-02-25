# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 4.x     | Yes       |
| < 4.0   | No        |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public issue
2. Email the maintainer directly or use GitHub's [private vulnerability reporting](https://github.com/superfeldy/ava-doorbell/security/advisories/new)
3. Include steps to reproduce and potential impact
4. Allow reasonable time for a fix before public disclosure

## Security Design

- **No default passwords** — setup wizard requires setting credentials
- **API tokens** — hashed in config, never stored in plaintext
- **Android token storage** — EncryptedSharedPreferences (AES via Tink)
- **Config writes** — atomic (tmp + fsync + rename) to prevent corruption
- **Command injection** — service management uses a strict whitelist
- **WebSocket limits** — 64KB max message size to prevent DoS
- **Protected keys** — admin credentials cannot be modified via REST API
- **MQTT** — anonymous, LAN-only (no internet exposure)
- **SSL/TLS** — auto-generated certificates for HTTPS companion server
