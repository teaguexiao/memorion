"""Remove durable recording data when its owner deletes it explicitly."""
from google.cloud.firestore_v1 import FieldFilter

from .artifacts import Artifacts
from .store import JobStore, owner_key
from .state import event


def delete_owner_jobs(developer_id, uid, *, store=None, artifacts=None, soniox=None):
    store = store or JobStore()
    artifacts = artifacts or Artifacts()
    snapshots = list(store.collection.where(
        filter=FieldFilter('owner_key', '==', owner_key(developer_id, uid))).stream())
    if not snapshots:
        return

    def cancel(job, now):
        if job:
            job.update(status='cancelled', dispatch_at=None, lease_token=None,
                       lease_until=0, upload_token=None, upload_until=0)
            event(job, now, 'owner_deleted')

    # Fence every queued/running job before deleting any conversation or object.
    for snapshot in snapshots:
        store.change(snapshot.id, cancel)
    if soniox is None:
        from .soniox import Soniox
        soniox = Soniox()
    for snapshot in snapshots:
        job = snapshot.to_dict()
        if job.get('is_root'):
            soniox.cleanup(job.get('checkpoints', {}))
        # Include abandoned upload tokens and all intermediate text artifacts.
        for blob in artifacts.bucket.list_blobs(prefix=f'audio_jobs/{snapshot.id}/'):
            blob.delete()
        snapshot.reference.delete()
