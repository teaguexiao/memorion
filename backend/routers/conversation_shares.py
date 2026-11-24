"""Sharing has its own Firebase auth boundary; developer/App shared keys never work."""
import hashlib
import ipaddress
import os
import re
from datetime import datetime, timezone
from typing import Literal
from uuid import UUID

import firebase_admin
from firebase_admin import auth as firebase_auth
from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, ConfigDict, Field

from models.developer import MEMORION_APP_DEVELOPER_ID
from utils.sharing.content import active, public_content
from utils.sharing.store import ShareConflict, ShareMissing, ShareStore

router = APIRouter(tags=['conversation-sharing'])
bearer = HTTPBearer(auto_error=False)
TOKEN = re.compile(r'^[a-f0-9]{64}\.[A-Za-z0-9_-]{43}$')


def enabled():
    # Deploy independently; explicitly enable only after the privacy/auth review.
    if os.getenv('CONVERSATION_SHARING_ENABLED', '').lower() != 'true':
        raise HTTPException(503, 'Sharing is unavailable')


def get_store():
    from database._client import db
    return ShareStore(db)


def firebase_app():
    # Fail closed: App users belong to the named user-facing Firebase project.
    try:
        return firebase_admin.get_app('fcm')
    except ValueError:
        raise HTTPException(503, 'Sharing is temporarily unavailable') from None


def check_account(uid):
    # Intentionally uncached: disabled/deleted Firebase accounts must fail closed
    # on the next read. Requests are bounded per visitor and per capability.
    try:
        if firebase_auth.get_user(uid, app=firebase_app()).disabled:
            raise ShareMissing()
    except firebase_auth.UserNotFoundError:
        raise ShareMissing() from None


def limit(key, count, seconds):
    from database.redis_db import r
    digest = hashlib.sha256(key.encode()).hexdigest()
    # One atomic distributed window, shared across ECS instances. No tokens/PII
    # in the Redis key. A Redis failure must not disable abuse protection.
    script = "local n=redis.call('INCR',KEYS[1]); if n==1 then redis.call('EXPIRE',KEYS[1],ARGV[1]) end; return n"
    try:
        hits = r.eval(script, 1, f'share-rate:{digest}', seconds)
    except Exception:
        raise HTTPException(503, 'Sharing is temporarily unavailable') from None
    if int(hits) > count:
        raise HTTPException(429, 'Too many requests', headers={'Retry-After': str(seconds)})


def network_limit(request: Request):
    host = request.client.host if request.client else 'unknown'
    # ECS only accepts traffic from the ALB security group. Trust the last
    # address appended by that ALB, never a caller-supplied leftmost address.
    # Keep this local to sharing rather than change proxy trust for all routes.
    cidrs = [value.strip() for value in os.getenv('SHARE_TRUSTED_PROXY_CIDRS', '').split(',') if value.strip()]
    try:
        peer = ipaddress.ip_address(host) if cidrs else None
        if any(peer in ipaddress.ip_network(cidr) for cidr in cidrs):
            forwarded = request.headers.get('x-forwarded-for', '').split(',')[-1].strip()
            host = str(ipaddress.ip_address(forwarded))
    except ValueError:
        # Deliberately fail closed: ALB append mode always provides a valid
        # last address. Falling back would merge all visitors into one bucket.
        raise HTTPException(503, 'Sharing is temporarily unavailable') from None
    limit(f'ip:{host}', 240, 60)


def owner_auth(request: Request, credentials: HTTPAuthorizationCredentials | None = Security(bearer)):
    enabled()
    network_limit(request)
    if not credentials or credentials.scheme.lower() != 'bearer':
        raise HTTPException(401, 'Sign in to manage sharing')
    app = firebase_app()
    try:
        decoded = firebase_auth.verify_id_token(credentials.credentials, app=app, check_revoked=True)
        uid = decoded['uid']
    except Exception:
        raise HTTPException(401, 'Sign in to manage sharing') from None
    from database.developers import get_developer
    developer = get_developer(MEMORION_APP_DEVELOPER_ID)
    if not developer or not developer.is_active:
        raise HTTPException(403, 'Sharing is unavailable')
    limit(f'owner:{uid}', 60, 60)
    return uid


class CreateShare(BaseModel):
    model_config = ConfigDict(extra='forbid')
    conversation_id: str = Field(pattern=r'^[A-Za-z0-9_-]{1,128}$')
    expiry_mode: Literal['seven_days', 'never']
    request_id: UUID


class RotateShare(BaseModel):
    model_config = ConfigDict(extra='forbid')
    request_id: UUID


class ReportShare(BaseModel):
    model_config = ConfigDict(extra='forbid')
    reason: Literal['privacy', 'permission', 'inappropriate', 'other']


def present(record):
    return {k: record.get(k) for k in ('id', 'conversation_id', 'created_at', 'expires_at', 'expiry_mode', 'revoked_at')} | {
        'active': active(record, datetime.now(timezone.utc))}


def created(record, token):
    return present(record) | {'url': f'https://memorion.me/s#{token}'}


def missing():
    return HTTPException(404, 'Share unavailable')


@router.post('/v1/shares', status_code=201)
def create_share(body: CreateShare, uid=Depends(owner_auth), store=Depends(get_store)):
    limit(f'create:{uid}', 30, 86400)
    try:
        record, token = store.create(MEMORION_APP_DEVELOPER_ID, uid, body.conversation_id,
                                     body.expiry_mode, str(body.request_id))
        return created(record, token)
    except ShareMissing:
        raise missing() from None
    except ShareConflict:
        raise HTTPException(409, 'A share already exists; refresh and manage it') from None


@router.get('/v1/shares')
def list_shares(conversation_id: str = Query(pattern=r'^[A-Za-z0-9_-]{1,128}$'),
                uid=Depends(owner_auth), store=Depends(get_store)):
    return [present(row) for row in store.list_for_conversation(MEMORION_APP_DEVELOPER_ID, uid, conversation_id)]


@router.delete('/v1/shares/{sid}', status_code=204)
def revoke_share(sid: str, uid=Depends(owner_auth), store=Depends(get_store)):
    if not re.fullmatch('[a-f0-9]{64}', sid):
        raise missing()
    try:
        store.revoke(MEMORION_APP_DEVELOPER_ID, uid, sid)
    except ShareMissing:
        raise missing() from None


@router.post('/v1/shares/{sid}/rotate')
def rotate_share(sid: str, body: RotateShare, uid=Depends(owner_auth), store=Depends(get_store)):
    if not re.fullmatch('[a-f0-9]{64}', sid):
        raise missing()
    limit(f'create:{uid}', 30, 86400)
    try:
        previous = store.get_owned(MEMORION_APP_DEVELOPER_ID, uid, sid)
        record, token = store.create(MEMORION_APP_DEVELOPER_ID, uid, previous['conversation_id'],
                                     previous['expiry_mode'], str(body.request_id), rotate=True)
        return created(record, token)
    except ShareMissing:
        raise missing() from None
    except ShareConflict:
        raise HTTPException(409, 'Refresh sharing and try again') from None


def public_auth(request: Request, token: str | None = Header(default=None, alias='X-Share-Token'),
                store=Depends(get_store)):
    enabled()
    network_limit(request)
    if not token or not TOKEN.fullmatch(token):
        raise missing()
    limit(f'token:{hashlib.sha256(token.encode()).hexdigest()}', 120, 60)
    try:
        record = store.resolve(token)
        check_account(record['owner_uid'])
    except ShareMissing:
        raise missing() from None
    return token, record


def load_conversation(record):
    from database.developer_data import get_conversation
    return get_conversation(record['developer_id'], record['owner_uid'], record['conversation_id'], include_photos=False)


@router.post('/v1/share-resolve')
def resolve_share(auth=Depends(public_auth), store=Depends(get_store)):
    token, record = auth
    conversation = load_conversation(record)
    if (not conversation or conversation.get('discarded')
            or conversation.get('created_at') != record.get('source_created_at')):
        raise missing()
    if conversation.get('status', 'completed') != 'completed':
        raise HTTPException(503, 'Content is being updated')
    try:
        payload = public_content(conversation, record)
        # Recheck all incarnation and disabled/deleted-source guards: checking
        # only the share doc could return content after account/source deletion.
        store.resolve(token)
        return payload
    except ShareMissing:
        raise missing() from None
    except ValueError:
        raise HTTPException(413, 'Shared content is too large') from None


@router.post('/v1/share-report', status_code=204)
def report_share(body: ReportShare, auth=Depends(public_auth), store=Depends(get_store)):
    _, record = auth
    limit(f'report:{record["id"]}', 10, 3600)
    store.report(record, body.reason)
