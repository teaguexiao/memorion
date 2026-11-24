import hashlib
import json
import os
import uuid

from dotenv import load_dotenv
load_dotenv()

from google.cloud import firestore
from google.oauth2 import service_account
from utils.runtime.credentials import materialize_gcp_credentials_from_env

materialize_gcp_credentials_from_env()

# Initialize Firestore client with proper credentials
db = None

if os.environ.get('SERVICE_ACCOUNT_JSON'):
    service_account_info = json.loads(os.environ["SERVICE_ACCOUNT_JSON"])
    credentials = service_account.Credentials.from_service_account_info(service_account_info)
    db = firestore.Client(credentials=credentials, project=service_account_info.get('project_id'))
elif os.environ.get('GOOGLE_APPLICATION_CREDENTIALS'):
    cred_path = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
    if os.path.exists(cred_path):
        credentials = service_account.Credentials.from_service_account_file(cred_path)
        with open(cred_path) as f:
            cred_info = json.load(f)
        db = firestore.Client(credentials=credentials, project=cred_info.get('project_id'))
    else:
        db = firestore.Client()
else:
    db = firestore.Client()


# Initialize secondary Firestore client for the optional Firebase Auth project
fcm_db = None

_fcm_cred_path = os.environ.get('FCM_GOOGLE_APPLICATION_CREDENTIALS', '')
if os.path.exists(_fcm_cred_path):
    _fcm_credentials = service_account.Credentials.from_service_account_file(_fcm_cred_path)
    with open(_fcm_cred_path) as _f:
        _fcm_info = json.load(_f)
    fcm_db = firestore.Client(credentials=_fcm_credentials, project=_fcm_info.get('project_id'))
elif os.environ.get('FCM_SERVICE_ACCOUNT_JSON'):
    _fcm_info = json.loads(os.environ['FCM_SERVICE_ACCOUNT_JSON'])
    _fcm_credentials = service_account.Credentials.from_service_account_info(_fcm_info)
    fcm_db = firestore.Client(credentials=_fcm_credentials, project=_fcm_info.get('project_id'))


def get_users_uid():
    users_ref = db.collection('users')
    return [str(doc.id) for doc in users_ref.stream()]


def document_id_from_seed(seed: str) -> uuid.UUID:
    """Avoid repeating the same data"""
    seed_hash = hashlib.sha256(seed.encode('utf-8')).digest()
    generated_uuid = uuid.UUID(bytes=seed_hash[:16], version=4)
    return str(generated_uuid)
