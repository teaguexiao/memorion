"""Real Firestore transactions, against a localhost-only emulator."""
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from utils.sharing.store import ShareStore, ShareConflict, ShareMissing


@pytest.fixture
def emulator():
    host = os.getenv('FIRESTORE_EMULATOR_HOST', '')
    if not host.startswith('127.0.0.1:'):
        pytest.skip('Requires localhost Firestore emulator; never uses production')
    db = firestore.Client(project='demo-memorion-sharing', credentials=AnonymousCredentials())
    store = ShareStore(db)
    dev, uid = 'test-' + uuid4().hex, 'owner'
    now = datetime.now(timezone.utc)
    parent = store.owner(dev, uid)
    db.collection('developer_data').document(dev).set({'is_active': True})
    parent.set({'created_at': now})
    parent.collection('conversations').document('source').set({'created_at': now, 'status': 'completed'})
    yield db, store, dev, uid
    store.delete_owner(dev, uid)
    parent.collection('conversations').document('source').delete()
    parent.delete()
    db.collection('developer_data').document(dev).delete()
    db.close()


def test_transaction_concurrent_create_rotation_and_cleanup(emulator):
    db, store, dev, uid = emulator
    def attempt(_):
        try:
            return store.create(dev, uid, 'source', 'never', str(uuid4()))
        except ShareConflict:
            return None
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(attempt, range(4)))
    winners = [r for r in results if r is not None]
    assert len(winners) == 1
    record, token = winners[0]
    assert store.resolve(token)['id'] == record['id']
    assert len(store.list_for_conversation(dev, uid, 'source')) == 1
    rotated, next_token = store.create(dev, uid, 'source', 'never', str(uuid4()), rotate=True)
    assert rotated['created_at'] == record['created_at']
    with pytest.raises(ShareMissing): store.resolve(token)
    store.revoke(dev, uid, record['id'])
    with pytest.raises(ShareMissing): store.resolve(next_token)
    store.delete_owner(dev, uid)
    assert not store.ref(record['id']).get().exists


def test_source_delete_and_recreate_cannot_revive_link(emulator):
    _, store, dev, uid = emulator
    _, token = store.create(dev, uid, 'source', 'seven_days', str(uuid4()))
    ref = store.owner(dev, uid).collection('conversations').document('source')
    ref.delete()
    with pytest.raises(ShareMissing): store.resolve(token)
    ref.set({'created_at': datetime.now(timezone.utc), 'status': 'completed'})
    with pytest.raises(ShareMissing): store.resolve(token)


def test_legacy_owner_gets_stable_generation_without_forged_timestamp(emulator):
    db, store, dev, uid = emulator
    owner = store.owner(dev, uid)
    owner.set({'legacy': True})
    record, token = store.create(dev, uid, 'source', 'never', str(uuid4()))
    data = owner.get().to_dict()
    assert 'created_at' not in data
    assert data['sharing_incarnation'] == record['owner_incarnation']
    assert store.resolve(token)['id'] == record['id']
    owner.delete()
    owner.set({'legacy': True})
    with pytest.raises(ShareMissing):
        store.resolve(token)
