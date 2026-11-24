import hashlib
import secrets
from typing import Tuple, Optional

from models.developer import ApiKeyEnvironment


def generate_developer_api_key(environment: ApiKeyEnvironment) -> Tuple[str, str, str]:
    """
    Generates a new developer API key.

    Format: memorion_dev_{env}_{32-char-hex}

    Args:
        environment: The environment (dev/prod) for this key

    Returns:
        Tuple of (raw_key, hashed_key, key_prefix)
    """
    secret_part = secrets.token_hex(16)  # 32 hex characters
    env_str = environment.value
    raw_key = f"memorion_dev_{env_str}_{secret_part}"
    hashed_key = hash_api_key(secret_part)
    key_prefix = f"memorion_dev_{env_str}_{secret_part[:4]}...{secret_part[-4:]}"
    return raw_key, hashed_key, key_prefix


def hash_api_key(secret: str) -> str:
    """
    Hashes an API key secret using SHA256.

    Args:
        secret: The secret portion of the API key to hash

    Returns:
        SHA256 hex digest of the secret
    """
    return hashlib.sha256(secret.encode()).hexdigest()


def parse_api_key(raw_key: str) -> Optional[Tuple[str, ApiKeyEnvironment, str]]:
    """
    Parses a raw API key into its components.

    Args:
        raw_key: The full API key (e.g., memorion_dev_prod_abc123...)

    Returns:
        Tuple of (prefix, environment, secret_part) or None if invalid format
    """
    if not raw_key or not raw_key.startswith("memorion_dev_"):
        return None

    try:
        # Remove the memorion_dev_ prefix
        remainder = raw_key.replace("memorion_dev_", "", 1)

        # Split on first underscore to get environment and secret
        parts = remainder.split("_", 1)
        if len(parts) != 2:
            return None

        env_str, secret_part = parts

        # Validate environment
        try:
            environment = ApiKeyEnvironment(env_str)
        except ValueError:
            return None

        # Validate secret part (should be 32 hex chars)
        if len(secret_part) != 32:
            return None

        prefix = f"memorion_dev_{env_str}"
        return prefix, environment, secret_part

    except Exception:
        return None
