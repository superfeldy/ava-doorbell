"""
AVA Doorbell v4.0 — Pydantic Models

Request/response validation and config schema definitions.
"""

from typing import Optional
from pydantic import BaseModel, Field


# ============================================================================
# Camera
# ============================================================================

class CameraConfig(BaseModel):
    id: str
    name: str
    url: str = ""
    main_url: str = ""
    type: str = "direct"  # "direct" | "nvr"
    talk_enabled: bool = False
    channel: Optional[int] = None
    rotation: int = 0  # 0, 90, 180, 270


class CameraCreate(BaseModel):
    name: str
    url: str = Field(..., pattern=r"^rtsp://")
    main_url: str = ""
    type: str = "direct"
    talk_enabled: bool = False
    channel: Optional[int] = None
    rotation: int = 0


class CameraUpdate(BaseModel):
    name: Optional[str] = None
    url: Optional[str] = None
    main_url: Optional[str] = None
    type: Optional[str] = None
    talk_enabled: Optional[bool] = None
    channel: Optional[int] = None
    rotation: Optional[int] = None


# ============================================================================
# Config Sections
# ============================================================================

class ServerConfig(BaseModel):
    admin_port: int = 5000
    go2rtc_port: int = 1984
    go2rtc_tls_port: int = 1985
    talk_port: int = 5001
    mqtt_broker: str = "localhost"
    mqtt_port: int = 1883


class AdminConfig(BaseModel):
    password_hash: str = ""
    api_token_hash: str = ""
    session_timeout_minutes: int = 60
    setup_complete: bool = False


class DoorbellConfig(BaseModel):
    ip: str = ""
    username: str = "admin"
    password: str = ""
    rtsp_port: int = 554
    sdk_port: int = 37777
    events: list[str] = Field(default_factory=lambda: [
        "DoorBell", "AlarmLocal", "VideoMotion", "CallNoAnswered"
    ])


class NvrConfig(BaseModel):
    ip: str = ""
    username: str = "admin"
    password: str = ""
    rtsp_port: int = 554
    max_channels: int = 16
    doorbell_channel: Optional[int] = None


class NotificationConfig(BaseModel):
    mqtt_topic_ring: str = "doorbell/ring"
    mqtt_topic_event: str = "doorbell/event"
    mqtt_topic_status: str = "doorbell/status"
    ring_cooldown_seconds: int = 10


class PresetLayout(BaseModel):
    name: str
    size: str = "4up"  # single, 2up, 4up, 6up, 8up, 9up
    cameras: list[str] = Field(default_factory=list)


class AutoCycleConfig(BaseModel):
    enabled: bool = False
    interval_seconds: int = 30
    presets: list[str] = Field(default_factory=list)


class SmbSharesConfig(BaseModel):
    config: bool = True
    services: bool = True
    recordings: bool = True


class SmbConfig(BaseModel):
    enabled: bool = False
    workgroup: str = "WORKGROUP"
    shares: SmbSharesConfig = Field(default_factory=SmbSharesConfig)


# ============================================================================
# API Request/Response
# ============================================================================

class LoginRequest(BaseModel):
    password: str


class PasswordChangeRequest(BaseModel):
    old_password: str
    new_password: str = Field(..., min_length=6)


class TokenRequest(BaseModel):
    password: str


class TokenResponse(BaseModel):
    token: str


class SetupPasswordRequest(BaseModel):
    password: str


class SetupCompleteRequest(BaseModel):
    pass


class SettingsUpdate(BaseModel):
    """Generic settings update — accepts arbitrary key/value pairs."""
    class Config:
        extra = "allow"
