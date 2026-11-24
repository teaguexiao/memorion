"""
Firmware OTA update router — multi-device support.

Directory layout:
    backend/firmware_releases/
        devkitv1/   — nRF52840 DevKit v1 firmware (.zip / .uf2)
        devkitv2/   — nRF52840 DevKit v2 (Adafruit) firmware (.zip / .uf2)
        glass/      — ESP32-S3 Omi Glass firmware (.bin / .uf2 / .zip)

Each device is identified by its BLE DIS Model Number string,
which the App reads and passes as `device_model` query param.
"""

from typing import Dict, Optional, Tuple
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse

FIRMWARE_DIR = Path(__file__).parent.parent / "firmware_releases"

# ──────────────────────────────────────────────
# Per-device firmware metadata
# Update the corresponding entry when you build
# a new firmware for that device.
# ──────────────────────────────────────────────

DEVICE_FIRMWARE: Dict[str, dict] = {
    "devkitv2": {
        "version": "2026.04.08-r8",
        "min_version": "0.0.0",
        "min_app_version": "0.0.0",
        "min_app_version_code": "0",
        "changelog": [
            "LED brightness control via BLE Settings Service",
            "NVS persistence for LED dim ratio",
        ],
        "ota_update_steps": ["battery", "no_usb"],
        "is_legacy_secure_dfu": True,
        "filename": "dfu_application.zip",
        "subdir": "devkitv2",
    },
    "devkitv1": {
        "version": "2026.06.25",
        "min_version": "0.0.0",
        "min_app_version": "0.0.0",
        "min_app_version_code": "0",
        "changelog": [],
        "ota_update_steps": ["battery", "no_usb"],
        "is_legacy_secure_dfu": True,
        "filename": "dfu_application.zip",
        "subdir": "devkitv1",
    },
    "glass": {
        "version": "2026.04.08",  # placeholder — update when glass firmware is built
        "min_version": "0.0.0",
        "min_app_version": "0.0.0",
        "min_app_version_code": "0",
        "changelog": [],
        "ota_update_steps": ["battery"],
        "is_legacy_secure_dfu": False,
        "filename": "omi_glass_firmware.zip",
        "subdir": "glass",
    },
}

# Map BLE DIS Model Number → device key
# Add aliases as needed (case-insensitive matching is done at lookup time)
_MODEL_ALIASES: Dict[str, str] = {
    # Memorion devices
    "memorion": "devkitv1",
    "memorion devkit 1": "devkitv1",
    "memorion devkit 2": "devkitv2",
    "memorion glass": "glass",
    # Legacy Friend devices → upgrade to Memorion (devkitv1) firmware
    "friend": "devkitv1",
    "friend devkit 1": "devkitv1",
    "friend devkit v1": "devkitv1",
    "friend devkit 1 spi sd": "devkitv1",
    # Legacy Omi devices → upgrade to Memorion (devkitv2) firmware
    "omi": "devkitv2",
    "omi evt": "devkitv2",
    "omi cv 1": "devkitv2",
    # Glass aliases
    "omi glass": "glass",
    "openglass": "glass",
}

router = APIRouter()


# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────


def _resolve_device(device_model: str) -> Optional[dict]:
    """Resolve a BLE model string to firmware metadata dict."""
    key = device_model.strip().lower()

    # Direct key match (e.g. "devkitv2")
    if key in DEVICE_FIRMWARE:
        return DEVICE_FIRMWARE[key]

    # Alias match
    if key in _MODEL_ALIASES:
        return DEVICE_FIRMWARE[_MODEL_ALIASES[key]]

    return None


def _firmware_path(meta: dict) -> Path:
    """Return the full path to the firmware file for a device."""
    return FIRMWARE_DIR / meta["subdir"] / meta["filename"]


def _has_firmware(meta: dict) -> bool:
    return _firmware_path(meta).exists()


def _parse_firmware_version(version_str: Optional[str]) -> Tuple[int, ...]:
    """Parse a version string like '2026.03.12-r3' into a comparable tuple.

    The base date parts (2026.03.12) are parsed first, then an optional
    '-rN' revision suffix is appended (defaulting to 0 if absent).
    Example: '2026.03.12-r5' -> (2026, 3, 12, 5)
    """
    if not version_str:
        return (0, 0, 0, 0)

    normalized = version_str.lower().lstrip("v")

    # Split base version and optional suffix
    parts_split = normalized.split("-", 1)
    base = parts_split[0]

    # Parse revision suffix like 'r3' -> 3
    revision = 0
    if len(parts_split) > 1:
        suffix = parts_split[1]
        if suffix.startswith("r") and suffix[1:].isdigit():
            revision = int(suffix[1:])

    parts = base.split(".")
    version_tuple = []
    for part in parts:
        try:
            version_tuple.append(int(part))
        except ValueError:
            return (0, 0, 0, 0)

    while len(version_tuple) < 3:
        version_tuple.append(0)

    version_tuple.append(revision)

    return tuple(version_tuple)


# ──────────────────────────────────────────────
# Routes
# ──────────────────────────────────────────────


@router.get("/v2/firmware/latest")
async def get_latest_version(
    request: Request,
    device_model: str,
    firmware_revision: str,
    hardware_revision: str,
    manufacturer_name: str,
):
    """Return latest firmware info for the given device model."""
    meta = _resolve_device(device_model)
    if meta is None:
        raise HTTPException(
            status_code=404,
            detail=f"Unknown device model: {device_model}",
        )

    # Only serve firmware to devices from known manufacturers
    known_manufacturers = {"based hardware"}
    if manufacturer_name.strip().lower() not in known_manufacturers:
        raise HTTPException(
            status_code=404,
            detail=f"Unknown manufacturer: {manufacturer_name}",
        )

    if not _has_firmware(meta):
        raise HTTPException(status_code=404, detail="No firmware available for this device")

    custom_version = _parse_firmware_version(meta["version"])
    device_version = _parse_firmware_version(firmware_revision)

    if custom_version <= device_version:
        raise HTTPException(status_code=404, detail="Already on latest firmware")

    # Build download URL with device key so /download knows which file to serve
    device_key = _MODEL_ALIASES.get(device_model.strip().lower(), device_model.strip().lower())
    base_url = str(request.base_url).rstrip("/")

    return {
        "version": meta["version"],
        "min_version": meta["min_version"],
        "min_app_version": meta["min_app_version"],
        "min_app_version_code": meta["min_app_version_code"],
        "zip_url": f"{base_url}/v2/firmware/download?device={device_key}",
        "draft": False,
        "ota_update_steps": meta["ota_update_steps"],
        "is_legacy_secure_dfu": meta["is_legacy_secure_dfu"],
        "changelog": meta["changelog"],
    }


@router.get("/v2/firmware/download")
async def download_firmware(device: str = "devkitv2"):
    """Serve the firmware file for the given device key."""
    meta = DEVICE_FIRMWARE.get(device)
    if meta is None:
        raise HTTPException(status_code=404, detail=f"Unknown device: {device}")

    fw_path = _firmware_path(meta)
    if not fw_path.exists():
        raise HTTPException(status_code=404, detail="Firmware file not found")

    # Determine content type
    suffix = fw_path.suffix.lower()
    media_types = {
        ".zip": "application/zip",
        ".bin": "application/octet-stream",
        ".uf2": "application/octet-stream",
    }

    return FileResponse(
        path=str(fw_path),
        media_type=media_types.get(suffix, "application/octet-stream"),
        filename=meta["filename"],
    )
