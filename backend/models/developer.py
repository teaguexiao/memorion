import os
from datetime import datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field

# The official Memorion App developer account that owns all App user data
# (developer_data/{this}/users/{firebase_uid}/...).
#
# Lives here rather than in a router so both dependencies.py and routers/ can
# read it without dependencies.py having to import from routers/.
# Must stay in sync with DEFAULT_DEVELOPER_ID in backend/modal/memorion_daily_summary.py.
MEMORION_APP_DEVELOPER_ID = os.getenv(
    "MEMORION_APP_DEVELOPER_ID", ""
)


class DeveloperTier(str, Enum):
    FREE = "free"
    STARTER = "starter"
    PRO = "pro"
    ENTERPRISE = "enterprise"


class ApiKeyEnvironment(str, Enum):
    DEV = "dev"
    PROD = "prod"


class Developer(BaseModel):
    id: str
    email: str
    name: Optional[str] = None
    company_name: Optional[str] = None
    tier: DeveloperTier = DeveloperTier.FREE
    is_active: bool = True
    credits_balance: float = 0.0
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: Optional[datetime] = None


class ApiKey(BaseModel):
    id: str
    name: str
    key_prefix: str
    environment: ApiKeyEnvironment
    is_active: bool = True
    created_at: datetime
    last_used_at: Optional[datetime] = None
    # When set, the key may only act on this external_user_id. Requests that
    # target any other external_user_id are rejected with 403. None (default,
    # and the stored value for all pre-existing keys) means full developer
    # scope — behavior unchanged.
    bound_external_user_id: Optional[str] = None
    # Explicit opt-in to cross-user access, for platform jobs that legitimately
    # fan out over the whole user base (the Modal crons: daily summary, daily
    # quote, insights). Such a job can never be user-bound, so once unbound keys
    # start getting rejected (§9.5 阶段 3) it needs a way to say "yes, really".
    #
    # ⚠️ This must never be settable through POST /v1/keys — a flag that grants
    # cross-user access is exactly what an extracted key would want to set. The
    # router builds its own ApiKeyCreate from name+environment only, so the
    # field is unreachable from the outside; it is written by
    # scripts/mint_platform_cron_key.py.
    allow_any_user: bool = False


class ApiKeyDB(ApiKey):
    """Extended model with fields stored in database but not exposed to API"""
    developer_id: str
    hashed_key: str


class ApiKeyCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)
    environment: ApiKeyEnvironment = ApiKeyEnvironment.DEV
    bound_external_user_id: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=200,
        description="Restrict this key to a single external_user_id (used by CLI login keys)",
    )
    # See ApiKey.allow_any_user. Present here only so the minting script can set
    # it; routers/api_keys.py deliberately reconstructs this model from
    # name+environment, so an API caller cannot reach it.
    allow_any_user: bool = False


class ApiKeyCreated(ApiKey):
    """Response model that includes the raw key (shown only once)"""
    key: str
