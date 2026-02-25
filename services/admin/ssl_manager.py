"""
AVA Doorbell v4.0 — SSL Certificate Manager

Generates self-signed SSL certs with dynamic SAN based on current Pi IP.
Regenerates if the IP changes.
"""

import ipaddress
import logging
import subprocess
from pathlib import Path
from typing import Optional, Tuple

logger = logging.getLogger(__name__)


def get_cert_sans(cert_path: Path) -> set[str]:
    """Extract IP SANs from an existing certificate."""
    try:
        result = subprocess.run(
            ["openssl", "x509", "-in", str(cert_path), "-noout", "-text"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return set()

        sans = set()
        for line in result.stdout.split("\n"):
            line = line.strip()
            if "IP Address:" in line:
                # Parse "IP Address:10.10.10.167" entries
                for part in line.split(","):
                    part = part.strip()
                    if part.startswith("IP Address:"):
                        sans.add(part.split(":", 1)[1])
        return sans
    except Exception as e:
        logger.warning(f"Failed to read cert SANs: {e}")
        return set()


def ensure_ssl_cert(
    config_dir: Path, current_ip: str
) -> Tuple[Optional[str], Optional[str]]:
    """Generate self-signed SSL cert if not present or IP changed.

    Returns (cert_path, key_path) or (None, None) on failure.
    """
    # Validate IP before using it in cert SAN
    try:
        ipaddress.ip_address(current_ip)
    except ValueError:
        logger.error(f"Invalid IP address for SSL cert: {current_ip!r}")
        return None, None

    ssl_dir = config_dir / "ssl"
    cert_file = ssl_dir / "ava-admin.crt"
    key_file = ssl_dir / "ava-admin.key"

    # Check if existing cert covers current IP
    if cert_file.exists() and key_file.exists():
        existing_sans = get_cert_sans(cert_file)
        if current_ip in existing_sans:
            logger.info(f"SSL cert valid for {current_ip}")
            return str(cert_file), str(key_file)
        logger.info(f"SSL cert missing SAN for {current_ip} (has: {existing_sans}), regenerating")

    # Generate new cert
    try:
        ssl_dir.mkdir(parents=True, exist_ok=True)

        san = f"IP:{current_ip},IP:127.0.0.1,DNS:localhost"
        result = subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", str(key_file),
                "-out", str(cert_file),
                "-days", "730",
                "-nodes",
                "-subj", "/CN=ava-doorbell/O=AVA/C=US",
                "-addext", f"subjectAltName={san}",
            ],
            capture_output=True, text=True, timeout=30,
        )

        if result.returncode == 0:
            logger.info(f"SSL cert generated for {current_ip}: {cert_file}")
            return str(cert_file), str(key_file)
        else:
            logger.error(f"SSL cert generation failed: {result.stderr}")
            return None, None
    except Exception as e:
        logger.error(f"SSL setup failed: {e}")
        return None, None
