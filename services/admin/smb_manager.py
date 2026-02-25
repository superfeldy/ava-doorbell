"""
AVA Doorbell v4.0 — Samba Configuration Manager

Generate and manage /etc/samba/ava-smb.conf from app config.
"""

import getpass
import logging
import os
import subprocess

logger = logging.getLogger(__name__)


def regenerate_smb_conf(config: dict) -> bool:
    """Regenerate /etc/samba/ava-smb.conf from config."""
    try:
        username = getpass.getuser()
        install_dir = os.path.expanduser("~/ava-doorbell")
        smb = config.get("smb", {})
        workgroup = smb.get("workgroup", "WORKGROUP")
        shares = smb.get("shares", {})

        conf_lines = [
            "# AVA Doorbell - Samba Configuration (auto-generated)",
            "# Do not edit manually - managed by AVA admin",
            "",
            "[global]",
            f"   workgroup = {workgroup}",
            "   server string = AVA Doorbell Pi",
            "   server role = standalone server",
            "   log file = /var/log/samba/log.%m",
            "   max log size = 1000",
            "   logging = file",
            "   obey pam restrictions = yes",
            "   unix password sync = no",
            "   map to guest = bad user",
            "   usershare allow guests = no",
            "   security = user",
            "   min protocol = SMB2",
            "   server min protocol = SMB2",
            "",
        ]

        share_defs = [
            ("config", "ava-config", "AVA Doorbell Configuration", f"{install_dir}/config", False),
            ("services", "ava-services", "AVA Doorbell Services", f"{install_dir}/services", False),
            ("recordings", "ava-recordings", "AVA Doorbell Recordings", f"{install_dir}/recordings", True),
        ]

        for key, name, comment, path, read_only in share_defs:
            if shares.get(key, True):
                if key == "recordings":
                    os.makedirs(path, exist_ok=True)
                conf_lines.extend([
                    f"[{name}]",
                    f"   comment = {comment}",
                    f"   path = {path}",
                    "   browseable = yes",
                    f"   read only = {'yes' if read_only else 'no'}",
                    f"   valid users = {username}",
                    "   create mask = 0644",
                    "   directory mask = 0755",
                    f"   force user = {username}",
                    "",
                ])

        conf_content = "\n".join(conf_lines) + "\n"

        tmp_path = "/tmp/ava-smb.conf"
        with open(tmp_path, "w") as f:
            f.write(conf_content)

        subprocess.run(
            ["sudo", "cp", tmp_path, "/etc/samba/ava-smb.conf"],
            capture_output=True, timeout=5,
        )
        os.remove(tmp_path)

        logger.info("Samba configuration regenerated")
        return True
    except Exception as e:
        logger.error(f"Failed to regenerate SMB config: {e}")
        return False
