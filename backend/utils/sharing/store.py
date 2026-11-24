"""One live link per owner/conversation; only hashed bearer secrets persist.

No content is stored here. A source incarnation check prevents a recreated
conversation with the same id from accidentally reviving an old link.
"""
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from hmac import compare_digest

from google.cloud import firestore
from google.cloud.firestore_v1 import FieldFilter

from .content import active


class ShareMissing(Exception):
    pass


class ShareConflict(Exception):
    pass


def owner_key(developer_id, uid):
    return hashlib.sha256(f'{developer_id}\0{uid}'.encode()).hexdigest()


def share_id(developer_id, uid, conversation_id):
    return hashlib.sha256(f'{owner_key(developer_id, uid)}\0{conversation_id}'.encode()).hexdigest()


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class ShareStore:
    def __init__(self, db):
        self.db = db

    def owner(self, developer_id, uid):
        return self.db.collection('developer_data').document(developer_id).collection('users').document(uid)

    def ref(self, sid):
        return self.db.collection('conversation_shares').document(sid)

    def create(self, developer_id, uid, cid, mode, request_id, rotate=False):
        sid = share_id(developer_id, uid, cid)
        ref = self.ref(sid)
        token = f'{sid}.{secrets.token_urlsafe(32)}'
        now = datetime.now(timezone.utc)
        owner = self.owner(developer_id, uid)
        source = owner.collection('conversations').document(cid)

        @firestore.transactional
        def write(tx):
            parent = owner.get(transaction=tx)
            source_doc = source.get(transaction=tx)
            previous = ref.get(transaction=tx)
            conv = source_doc.to_dict() or {}
            if (not parent.exists or not source_doc.exists or conv.get('discarded')
                    or conv.get('status', 'completed') != 'completed'):
                raise ShareMissing()
            old = previous.to_dict() or {}
            if old.get('request_id') == request_id:
                # Plaintext tokens cannot be recovered. Caller lists the link
                # and explicitly regenerates after a lost response.
                raise ShareConflict()
            if old.get('blocked_at') or (active(old, now) and not rotate):
                raise ShareConflict()
            if rotate and not previous.exists:
                raise ShareMissing()
            expiry = old.get('expires_at') if rotate else (now + timedelta(days=7) if mode == 'seven_days' else None)
            if rotate and not active(old, now):
                raise ShareMissing()
            parent_data = parent.to_dict() or {}
            incarnation = parent_data.get('sharing_incarnation') or parent_data.get('created_at')
            if incarnation is None:
                # Old user docs may have no creation timestamp. Persist a new
                # random generation, never invent a historical creation date.
                incarnation = secrets.token_hex(16)
                tx.update(owner, {'sharing_incarnation': incarnation})
            record = {
                'id': sid, 'developer_id': developer_id, 'owner_uid': uid,
                'owner_key': owner_key(developer_id, uid), 'conversation_id': cid,
                'source_created_at': conv.get('created_at'),
                'owner_incarnation': incarnation,
                'token_hash': token_hash(token), 'request_id': request_id,
                'created_at': old['created_at'] if rotate else now,
                'expiry_mode': old['expiry_mode'] if rotate else mode,
                'expires_at': expiry, 'revoked_at': None,
            }
            # Require stable incarnation metadata, rather than silently allow
            # an absent created_at to match a later recreated source.
            if record['source_created_at'] is None:
                raise ShareMissing()
            tx.set(ref, record)
            return record

        return write(self.db.transaction()), token

    def get_owned(self, developer_id, uid, sid):
        record = self.ref(sid).get().to_dict() or {}
        if record.get('owner_key') != owner_key(developer_id, uid):
            raise ShareMissing()
        return record

    def list_for_conversation(self, developer_id, uid, cid):
        try:
            return [self.get_owned(developer_id, uid, share_id(developer_id, uid, cid))]
        except ShareMissing:
            return []

    def resolve(self, token):
        sid = token.split('.')[0]
        record = self.ref(sid).get().to_dict() or {}
        if not compare_digest(record.get('token_hash', ''), token_hash(token)) or not active(record, datetime.now(timezone.utc)):
            raise ShareMissing()
        developer = self.db.collection('developer_data').document(record['developer_id']).get(field_paths=['is_active']).to_dict() or {}
        owner = self.owner(record['developer_id'], record['owner_uid'])
        parent = owner.get(field_paths=['created_at', 'sharing_incarnation']).to_dict() or {}
        source = owner.collection('conversations').document(record['conversation_id']).get(field_paths=['created_at', 'discarded']).to_dict() or {}
        if (not developer.get('is_active') or not parent or not source or source.get('discarded')
                or source.get('created_at') != record.get('source_created_at')
                or (parent.get('sharing_incarnation') or parent.get('created_at'))
                != record.get('owner_incarnation', record.get('owner_created_at'))):
            raise ShareMissing()
        return record

    def revoke(self, developer_id, uid, sid):
        ref = self.ref(sid)

        @firestore.transactional
        def write(tx):
            record = ref.get(transaction=tx).to_dict() or {}
            if record.get('owner_key') != owner_key(developer_id, uid):
                raise ShareMissing()
            tx.update(ref, {'revoked_at': datetime.now(timezone.utc)})

        write(self.db.transaction())

    def delete_owner(self, developer_id, uid):
        query = self.db.collection('conversation_shares').where(filter=FieldFilter('owner_key', '==', owner_key(developer_id, uid)))
        # The account/source presence check also fails closed during cleanup.
        for doc in query.stream():
            doc.reference.delete()

    def delete_source(self, developer_id, uid, cid):
        self.ref(share_id(developer_id, uid, cid)).delete()

    def report(self, record, reason):
        # One flag per reason, no visitor PII, no transcript copy, bounded writes.
        self.ref(record['id']).update({f'reports.{reason}': True, 'last_reported_at': datetime.now(timezone.utc)})
