import json
import os
from pathlib import Path


def _write_json_env_to_file(
    *,
    json_env_key: str,
    path_env_key: str,
    default_path: str,
) -> None:
    """
    Materialize service-account JSON env vars into files for libraries that
    still require GOOGLE_APPLICATION_CREDENTIALS-style paths.
    """
    json_value = os.environ.get(json_env_key)
    if not json_value:
        return

    existing_path = os.environ.get(path_env_key)
    if existing_path and os.path.exists(existing_path):
        return

    target_path = Path(existing_path or default_path)
    target_path.parent.mkdir(parents=True, exist_ok=True)

    # Validate the payload before writing so we fail fast on malformed secrets.
    parsed = json.loads(json_value)
    target_path.write_text(json.dumps(parsed), encoding="utf-8")
    os.chmod(target_path, 0o600)
    os.environ[path_env_key] = str(target_path)


def materialize_gcp_credentials_from_env() -> None:
    _write_json_env_to_file(
        json_env_key="SERVICE_ACCOUNT_JSON",
        path_env_key="GOOGLE_APPLICATION_CREDENTIALS",
        default_path="/tmp/memorion-service-account.json",
    )
    _write_json_env_to_file(
        json_env_key="FCM_SERVICE_ACCOUNT_JSON",
        path_env_key="FCM_GOOGLE_APPLICATION_CREDENTIALS",
        default_path="/tmp/memorion-fcm-service-account.json",
    )
