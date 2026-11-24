import datetime
import json
import os
from typing import Dict, Iterable, List, Optional

from google.api_core.exceptions import NotFound
from google.cloud import storage
from google.oauth2 import service_account
from google.cloud.storage import transfer_manager

from database.redis_db import cache_signed_url, get_cached_signed_url

if os.environ.get('SERVICE_ACCOUNT_JSON'):
    service_account_info = json.loads(os.environ["SERVICE_ACCOUNT_JSON"])
    credentials = service_account.Credentials.from_service_account_info(service_account_info)
    storage_client = storage.Client(credentials=credentials)
else:
    storage_client = storage.Client()

speech_profiles_bucket = os.getenv('BUCKET_SPEECH_PROFILES')
postprocessing_audio_bucket = os.getenv('BUCKET_POSTPROCESSING')
memories_recordings_bucket = os.getenv('BUCKET_MEMORIES_RECORDINGS')
syncing_local_bucket = os.getenv('BUCKET_TEMPORAL_SYNC_LOCAL')
omi_apps_bucket = os.getenv('BUCKET_PLUGINS_LOGOS')
app_thumbnails_bucket = os.getenv('BUCKET_APP_THUMBNAILS')
daily_summary_images_bucket = os.getenv('BUCKET_DAILY_SUMMARY_IMAGES')
conversation_photos_bucket = os.getenv('BUCKET_CONVERSATION_PHOTOS')


# *******************************************
# ************* SPEECH PROFILE **************
# *******************************************
def upload_profile_audio(file_path: str, uid: str):
    bucket = storage_client.bucket(speech_profiles_bucket)
    path = f'{uid}/speech_profile.wav'
    blob = bucket.blob(path)
    blob.upload_from_filename(file_path)
    return f'https://storage.googleapis.com/{speech_profiles_bucket}/{path}'


def get_user_has_speech_profile(uid: str) -> bool:
    bucket = storage_client.bucket(speech_profiles_bucket)
    blob = bucket.blob(f'{uid}/speech_profile.wav')
    return blob.exists()


def get_profile_audio_if_exists(uid: str, download: bool = True) -> str:
    bucket = storage_client.bucket(speech_profiles_bucket)
    path = f'{uid}/speech_profile.wav'
    blob = bucket.blob(path)
    if blob.exists():
        if download:
            file_path = f'_temp/{uid}_speech_profile.wav'
            blob.download_to_filename(file_path)
            return file_path
        return _get_signed_url(blob, 60)

    return None


def upload_additional_profile_audio(file_path: str, uid: str) -> None:
    bucket = storage_client.bucket(speech_profiles_bucket)
    path = f'{uid}/additional_profile_recordings/{file_path.split("/")[-1]}'
    blob = bucket.blob(path)
    blob.upload_from_filename(file_path)


def delete_additional_profile_audio(uid: str, file_name: str) -> None:
    bucket = storage_client.bucket(speech_profiles_bucket)
    blob = bucket.blob(f'{uid}/additional_profile_recordings/{file_name}')
    if blob.exists():
        print('delete_additional_profile_audio deleting', file_name)
        blob.delete()


def get_additional_profile_recordings(uid: str, download: bool = False) -> List[str]:
    bucket = storage_client.bucket(speech_profiles_bucket)
    blobs = bucket.list_blobs(prefix=f'{uid}/additional_profile_recordings/')
    if download:
        paths = []
        for blob in blobs:
            file_path = f'_temp/{uid}_{blob.name.split("/")[-1]}'
            blob.download_to_filename(file_path)
            paths.append(file_path)
        return paths

    return [_get_signed_url(blob, 60) for blob in blobs]


# ********************************************
# ************* PEOPLE PROFILES **************
# ********************************************


def upload_user_person_speech_sample(file_path: str, uid: str, person_id: str) -> None:
    bucket = storage_client.bucket(speech_profiles_bucket)
    path = f'{uid}/people_profiles/{person_id}/{file_path.split("/")[-1]}'
    blob = bucket.blob(path)
    blob.upload_from_filename(file_path)


def delete_user_person_speech_sample(uid: str, person_id: str, file_name: str) -> None:
    bucket = storage_client.bucket(speech_profiles_bucket)
    blob = bucket.blob(f'{uid}/people_profiles/{person_id}/{file_name}')
    if blob.exists():
        blob.delete()


def delete_speech_sample_for_people(uid: str, file_name: str) -> None:
    bucket = storage_client.bucket(speech_profiles_bucket)
    blobs = bucket.list_blobs(prefix=f'{uid}/people_profiles/')
    for blob in blobs:
        if file_name in blob.name:
            print('delete_speech_sample_for_people deleting', blob.name)
            blob.delete()


def delete_user_person_speech_samples(uid: str, person_id: str) -> None:
    bucket = storage_client.bucket(speech_profiles_bucket)
    blobs = bucket.list_blobs(prefix=f'{uid}/people_profiles/{person_id}/')
    for blob in blobs:
        blob.delete()


def get_user_people_ids(uid: str) -> List[str]:
    bucket = storage_client.bucket(speech_profiles_bucket)
    blobs = bucket.list_blobs(prefix=f'{uid}/people_profiles/')
    return [blob.name.split("/")[-2] for blob in blobs]


def get_user_person_speech_samples(uid: str, person_id: str, download: bool = False) -> List[str]:
    bucket = storage_client.bucket(speech_profiles_bucket)
    blobs = bucket.list_blobs(prefix=f'{uid}/people_profiles/{person_id}/')
    if download:
        paths = []
        for blob in blobs:
            file_path = f'_temp/{uid}_person_{blob.name.split("/")[-1]}'
            blob.download_to_filename(file_path)
            paths.append(file_path)
        return paths

    return [_get_signed_url(blob, 60) for blob in blobs]


# ****************************************************
# ************* DEVELOPER PEOPLE PROFILES ************
# ****************************************************
# GCS path: developers/{developer_id}/users/{external_user_id}/people_profiles/{person_id}/


def upload_developer_person_speech_sample(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    audio_bytes: bytes,
    sample_id: str,
    metadata: Optional[dict] = None,
) -> dict:
    """
    Upload a speech sample for a person in Developer API.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user identifier
        person_id: The person's ID
        audio_bytes: Raw audio bytes to upload
        sample_id: Unique identifier for this sample
        metadata: Provenance to attach to the blob — see
            ``database.developer_speech_profile.sample_provenance``

    Returns:
        dict with sample_id and sample_url
    """
    import io
    import wave

    # Convert raw audio bytes to WAV format
    wav_buffer = io.BytesIO()
    with wave.open(wav_buffer, 'wb') as wav_file:
        wav_file.setnchannels(1)  # mono
        wav_file.setsampwidth(2)  # 16-bit
        wav_file.setframerate(16000)  # 16kHz
        wav_file.writeframes(audio_bytes)

    wav_buffer.seek(0)
    bucket = storage_client.bucket(speech_profiles_bucket)
    path = f'developers/{developer_id}/users/{external_user_id}/people_profiles/{person_id}/{sample_id}.wav'
    blob = bucket.blob(path)
    if metadata:
        blob.metadata = metadata
    blob.upload_from_file(wav_buffer, content_type='audio/wav')

    return {
        'sample_id': sample_id,
        'sample_url': _get_signed_url(blob, 60)
    }


def upload_developer_person_speech_sample_from_file(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    file_path: str,
    sample_id: str,
    metadata: Optional[dict] = None,
) -> dict:
    """
    Upload a speech sample from file for a person in Developer API.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user identifier
        person_id: The person's ID
        file_path: Path to the audio file
        sample_id: Unique identifier for this sample
        metadata: Provenance to attach to the blob. Without it the sample is
            unrevokable: the filename is a bare uuid, so once the user takes the
            tag back there is no way to tell which wav that tag produced. Set it
            on the ``blob`` BEFORE upload so it lands in the same request —
            patching afterwards leaves a window where a concurrent
            identification run reads a sample with no provenance.

    Returns:
        dict with sample_id and sample_url
    """
    bucket = storage_client.bucket(speech_profiles_bucket)
    path = f'developers/{developer_id}/users/{external_user_id}/people_profiles/{person_id}/{sample_id}.wav'
    blob = bucket.blob(path)
    if metadata:
        blob.metadata = metadata
    blob.upload_from_filename(file_path)

    return {
        'sample_id': sample_id,
        'sample_url': _get_signed_url(blob, 60)
    }


def get_developer_person_speech_samples(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    download: bool = False
) -> List[str]:
    """
    Get speech samples for a person in Developer API.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user identifier
        person_id: The person's ID
        download: If True, download files and return local paths. If False, return signed URLs.

    Returns:
        List of signed URLs or local file paths
    """
    bucket = storage_client.bucket(speech_profiles_bucket)
    prefix = f'developers/{developer_id}/users/{external_user_id}/people_profiles/{person_id}/'
    blobs = list(bucket.list_blobs(prefix=prefix))

    if download:
        paths = []
        for blob in blobs:
            file_path = f'_temp/{developer_id}_{external_user_id}_{person_id}_{blob.name.split("/")[-1]}'
            blob.download_to_filename(file_path)
            paths.append(file_path)
        return paths

    return [_get_signed_url(blob, 60) for blob in blobs]


def get_developer_people_speech_sample_counts(
    developer_id: str,
    external_user_id: str,
) -> Dict[str, int]:
    """每个 person 的样本条数，**一次** prefix 列举全部拿到。

    存在的理由是列表页的延迟。``get_developer_person_speech_samples`` 是 per-person 的
    一次 GCS 列举 + 每个 blob 一次签名，列表页逐个调它 = 人数次往返：833 人的账号上
    ``GET /v1/people?include_speech_samples=true`` 单页实测 **15.65s**，而不带样本是
    2.38s —— 那 13 秒几乎全花在「列举 800 多个多数为空的前缀」上。而列表页要的只是
    「N 段样本」这个数字，URL 一条都用不到。

    这里换成对 ``people_profiles/`` 整体列举一次，按路径第一段归组。计数总是准的，
    不需要在 Firestore 上多养一个字段 —— 那种字段要在上传/删除/整人删除/撤销四条写
    路径上同步维护，漏一处就静默偏，还得给存量数据补一次。

    ⚠️ ``revoked_samples/`` 是 ``people_profiles/`` 的**兄弟**目录，所以撤销掉的样本
    天然不在这个前缀里（这也是当初不把 quarantine 放成子目录的原因之一）。
    """
    bucket = storage_client.bucket(speech_profiles_bucket)
    prefix = f'developers/{developer_id}/users/{external_user_id}/people_profiles/'
    counts: Dict[str, int] = {}
    for blob in bucket.list_blobs(prefix=prefix):
        rest = blob.name[len(prefix):]
        # 只数 {person_id}/{sample}.wav；前缀自身那条伪目录和更深的层级都跳过。
        if '/' not in rest or not rest.endswith('.wav'):
            continue
        person_id = rest.split('/', 1)[0]
        counts[person_id] = counts.get(person_id, 0) + 1
    return counts


def get_developer_person_speech_sample_count(
    developer_id: str,
    external_user_id: str,
    person_id: str,
) -> int:
    """单个 person 的样本条数。**不签 URL**，所以比
    ``len(get_developer_person_speech_samples(...))`` 便宜（后者每个 blob 都要签一次）。
    """
    bucket = storage_client.bucket(speech_profiles_bucket)
    prefix = f'developers/{developer_id}/users/{external_user_id}/people_profiles/{person_id}/'
    return sum(1 for blob in bucket.list_blobs(prefix=prefix) if blob.name.endswith('.wav'))


def delete_developer_person_speech_sample(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    sample_id: str
) -> bool:
    """
    Delete a specific speech sample for a person in Developer API.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user identifier
        person_id: The person's ID
        sample_id: The sample ID to delete

    Returns:
        True if deleted, False if not found
    """
    bucket = storage_client.bucket(speech_profiles_bucket)
    blob = bucket.blob(f'developers/{developer_id}/users/{external_user_id}/people_profiles/{person_id}/{sample_id}.wav')
    if blob.exists():
        blob.delete()
        return True
    return False


def delete_all_developer_person_speech_samples(
    developer_id: str,
    external_user_id: str,
    person_id: str
) -> int:
    """
    Delete all speech samples for a person in Developer API.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user identifier
        person_id: The person's ID

    Returns:
        Number of samples deleted
    """
    bucket = storage_client.bucket(speech_profiles_bucket)
    prefix = f'developers/{developer_id}/users/{external_user_id}/people_profiles/{person_id}/'
    blobs = list(bucket.list_blobs(prefix=prefix))
    count = 0
    for blob in blobs:
        blob.delete()
        count += 1
    return count


# ********************************************
# ************* POST PROCESSING **************
# ********************************************
def upload_postprocessing_audio(file_path: str):
    bucket = storage_client.bucket(postprocessing_audio_bucket)
    blob = bucket.blob(file_path)
    blob.upload_from_filename(file_path)
    return f'https://storage.googleapis.com/{postprocessing_audio_bucket}/{file_path}'


def delete_postprocessing_audio(file_path: str):
    bucket = storage_client.bucket(postprocessing_audio_bucket)
    blob = bucket.blob(file_path)
    blob.delete()


# ***********************************
# ************* SDCARD **************
# ***********************************


def upload_sdcard_audio(file_path: str):
    bucket = storage_client.bucket(postprocessing_audio_bucket)
    blob = bucket.blob(file_path)
    blob.upload_from_filename(file_path)
    return f'https://storage.googleapis.com/{postprocessing_audio_bucket}/sdcard/{file_path}'


def download_postprocessing_audio(file_path: str, destination_file_path: str):
    bucket = storage_client.bucket(postprocessing_audio_bucket)
    blob = bucket.blob(file_path)
    blob.download_to_filename(destination_file_path)


# ************************************************
# *********** CONVERSATIONS RECORDINGS ***********
# ************************************************


def upload_conversation_recording(file_path: str, uid: str, conversation_id: str):
    bucket = storage_client.bucket(memories_recordings_bucket)
    path = f'{uid}/{conversation_id}.wav'
    blob = bucket.blob(path)
    blob.upload_from_filename(file_path)
    return f'https://storage.googleapis.com/{memories_recordings_bucket}/{path}'


def get_conversation_recording_signed_url(uid: str, conversation_id: str, minutes: int = 60) -> str:
    """
    Generate a signed URL for a conversation recording.
    Used for audio playback when local audio is not available (e.g., Developer API uploads).

    Args:
        uid: User ID
        conversation_id: Conversation ID
        minutes: URL validity duration in minutes (default 60)

    Returns:
        Signed URL string, or empty string if recording doesn't exist
    """
    bucket = storage_client.bucket(memories_recordings_bucket)
    path = f'{uid}/{conversation_id}.wav'
    blob = bucket.blob(path)
    if not blob.exists():
        return ''
    return _get_signed_url(blob, minutes)


def get_signed_url_from_path(audio_path: str, minutes: int = 15) -> str:
    """
    Generate a short-lived signed URL from a GCS path.

    Args:
        audio_path: GCS path in format "{uid}/{conversation_id}.wav"
        minutes: URL validity duration in minutes (default 15)

    Returns:
        Signed URL string, or empty string if recording doesn't exist
    """
    if not audio_path:
        return ''
    bucket = storage_client.bucket(memories_recordings_bucket)
    blob = bucket.blob(audio_path)
    if not blob.exists():
        return ''
    return _get_signed_url(blob, minutes)


def get_conversation_audio_path(uid: str, conversation_id: str) -> str:
    """
    Get the GCS path for a conversation recording.
    This path can be stored in Firestore and used later to generate signed URLs.

    Args:
        uid: User ID
        conversation_id: Conversation ID

    Returns:
        GCS path string (e.g., "{uid}/{conversation_id}.wav")
    """
    return f'{uid}/{conversation_id}.wav'


def upload_conversation_recording_from_bytes(audio_bytes: bytes, uid: str, conversation_id: str, sample_rate: int = 16000):
    """Upload audio bytes directly to GCS as WAV file."""
    import io
    import wave

    wav_buffer = io.BytesIO()
    with wave.open(wav_buffer, 'wb') as wav_file:
        wav_file.setnchannels(1)  # mono
        wav_file.setsampwidth(2)  # 16-bit
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(audio_bytes)

    wav_buffer.seek(0)
    bucket = storage_client.bucket(memories_recordings_bucket)
    path = f'{uid}/{conversation_id}.wav'
    blob = bucket.blob(path)
    blob.upload_from_file(wav_buffer, content_type='audio/wav')
    return f'https://storage.googleapis.com/{memories_recordings_bucket}/{path}'


def get_conversation_recording_if_exists(uid: str, memory_id: str) -> str:
    print('get_conversation_recording_if_exists', uid, memory_id)
    bucket = storage_client.bucket(memories_recordings_bucket)
    path = f'{uid}/{memory_id}.wav'
    blob = bucket.blob(path)
    if blob.exists():
        file_path = f'_temp/{memory_id}.wav'
        blob.download_to_filename(file_path)
        return file_path
    return None


def download_recording_from_path(audio_path: str) -> str:
    """Download a conversation recording from an arbitrary GCS path in the recordings bucket."""
    if not audio_path:
        return None
    bucket = storage_client.bucket(memories_recordings_bucket)
    blob = bucket.blob(audio_path)
    if not blob.exists():
        return None
    safe_name = audio_path.replace('/', '_')
    file_path = f'_temp/{safe_name}'
    blob.download_to_filename(file_path)
    return file_path


def delete_conversation_recordings(paths: Iterable[str]):
    bucket = storage_client.bucket(memories_recordings_bucket)
    for path in paths:
        try:
            bucket.blob(path).delete()
        except NotFound:
            # Retrying an interrupted deletion can encounter objects already removed.
            continue


def delete_all_user_speech_data(uid: str):
    if not uid:
        return
    bucket = storage_client.bucket(speech_profiles_bucket)
    blobs = bucket.list_blobs(prefix=f'{uid}/')
    for blob in blobs:
        blob.delete()


# ********************************************
# ************* SYNCING FILES **************
# ********************************************
def get_syncing_file_temporal_url(file_path: str):
    bucket = storage_client.bucket(syncing_local_bucket)
    blob = bucket.blob(file_path)
    blob.upload_from_filename(file_path)
    return f'https://storage.googleapis.com/{syncing_local_bucket}/{file_path}'


def get_syncing_file_temporal_signed_url(file_path: str):
    bucket = storage_client.bucket(syncing_local_bucket)
    blob = bucket.blob(file_path)
    blob.upload_from_filename(file_path)
    return _get_signed_url(blob, 15)


def delete_syncing_temporal_file(file_path: str):
    bucket = storage_client.bucket(syncing_local_bucket)
    blob = bucket.blob(file_path)
    blob.delete()


# **********************************
# ************* UTILS **************
# **********************************


def _get_signed_url(blob, minutes):
    if cached := get_cached_signed_url(blob.name):
        return cached

    signed_url = blob.generate_signed_url(version="v4", expiration=datetime.timedelta(minutes=minutes), method="GET")
    cache_signed_url(blob.name, signed_url, minutes * 60)
    return signed_url


def upload_app_logo(file_path: str, app_id: str):
    bucket = storage_client.bucket(omi_apps_bucket)
    path = f'{app_id}.png'
    blob = bucket.blob(path)
    blob.cache_control = 'public, no-cache'
    blob.upload_from_filename(file_path)
    return f'https://storage.googleapis.com/{omi_apps_bucket}/{path}'


def delete_app_logo(img_url: str):
    bucket = storage_client.bucket(omi_apps_bucket)
    path = img_url.split(f'https://storage.googleapis.com/{omi_apps_bucket}/')[1]
    print('delete_app_logo', path)
    blob = bucket.blob(path)
    blob.delete()


def upload_app_thumbnail(file_path: str, thumbnail_id: str) -> str:
    bucket = storage_client.bucket(app_thumbnails_bucket)
    path = f'{thumbnail_id}.jpg'
    blob = bucket.blob(path)
    blob.cache_control = 'public, no-cache'
    blob.upload_from_filename(file_path)
    public_url = f'https://storage.googleapis.com/{app_thumbnails_bucket}/{path}'
    return public_url


def get_app_thumbnail_url(thumbnail_id: str) -> str:
    path = f'{thumbnail_id}.jpg'
    return f'https://storage.googleapis.com/{app_thumbnails_bucket}/{path}'


# ********************************************
# ******** DAILY SUMMARY IMAGES *************
# ********************************************
def upload_daily_summary_image(image_data: bytes, uid: str, date_str: str) -> str:
    """
    Upload a daily summary image to GCS.

    Args:
        image_data: PNG image bytes
        uid: User ID
        date_str: Date string in YYYY-MM-DD format

    Returns:
        Public URL of the uploaded image, versioned by the upload's GCS generation

    ⚠️ A day's picture always lands on the same object, and the App keeps pictures on disk by URL
    for 60 days (`DiaryImageCache`). Without the version a redrawn picture (a rewrite, or a
    catch-up that adds a lost one) kept showing the old one on phones that had already loaded it.
    """
    bucket = storage_client.bucket(daily_summary_images_bucket)
    path = f'{uid}/{date_str}_summary.png'
    blob = bucket.blob(path)
    blob.content_type = 'image/png'
    blob.cache_control = 'public, max-age=86400'  # Cache for 24 hours
    blob.upload_from_string(image_data, content_type='image/png')
    url = f'https://storage.googleapis.com/{daily_summary_images_bucket}/{path}'
    return f'{url}?v={blob.generation}' if blob.generation else url


def get_daily_summary_image_url(uid: str, date_str: str) -> str:
    """Get the public URL for a daily summary image."""
    return f'https://storage.googleapis.com/{daily_summary_images_bucket}/{uid}/{date_str}_summary.png'


# ************************************************
# *********** CONVERSATION PHOTOS ****************
# ************************************************

def upload_conversation_photo(
    image_data: bytes,
    uid: str,
    image_id: str,
    content_type: str = 'image/jpeg'
) -> str:
    """
    Upload a conversation photo to GCS.

    Args:
        image_data: Image bytes (JPEG or PNG)
        uid: User ID
        image_id: Unique image identifier
        content_type: MIME type (image/jpeg or image/png)

    Returns:
        GCS path for the uploaded image (not full URL)
    """
    bucket = storage_client.bucket(conversation_photos_bucket)
    extension = 'jpg' if content_type == 'image/jpeg' else 'png'
    path = f'{uid}/{image_id}.{extension}'
    blob = bucket.blob(path)
    blob.content_type = content_type
    blob.upload_from_string(image_data, content_type=content_type)
    return path


def upload_conversation_photo_base64(
    base64_data: str,
    uid: str,
    image_id: str,
) -> str:
    """
    Upload a base64-encoded conversation photo to GCS.

    Args:
        base64_data: Base64 encoded image data
        uid: User ID
        image_id: Unique image identifier

    Returns:
        GCS path for the uploaded image
    """
    import base64

    # Detect content type from base64 header or default to JPEG
    if base64_data.startswith('data:'):
        header, base64_data = base64_data.split(',', 1)
        if 'png' in header:
            content_type = 'image/png'
        else:
            content_type = 'image/jpeg'
    else:
        # Try to detect from magic bytes
        image_bytes = base64.b64decode(base64_data)
        if image_bytes[:8] == b'\x89PNG\r\n\x1a\n':
            content_type = 'image/png'
        else:
            content_type = 'image/jpeg'
        return upload_conversation_photo(image_bytes, uid, image_id, content_type)

    image_bytes = base64.b64decode(base64_data)
    return upload_conversation_photo(image_bytes, uid, image_id, content_type)


def get_conversation_photo_signed_url(
    uid: str,
    image_id: str,
    minutes: int = 15
) -> str:
    """
    Generate a signed URL for downloading a conversation photo.

    Args:
        uid: User ID
        image_id: Image identifier
        minutes: URL validity duration in minutes (default 15)

    Returns:
        Signed URL string, or empty string if image doesn't exist
    """
    bucket = storage_client.bucket(conversation_photos_bucket)

    # Try JPEG first, then PNG
    for ext in ['jpg', 'png']:
        path = f'{uid}/{image_id}.{ext}'
        blob = bucket.blob(path)
        if blob.exists():
            return _get_signed_url(blob, minutes)

    return ''


def get_conversation_photo_signed_url_from_path(
    gcs_path: str,
    minutes: int = 15
) -> str:
    """
    Generate a signed URL from a GCS path.

    Args:
        gcs_path: GCS path (e.g., "uid/image_id.jpg")
        minutes: URL validity duration in minutes

    Returns:
        Signed URL string, or empty string if image doesn't exist
    """
    if not gcs_path:
        return ''
    bucket = storage_client.bucket(conversation_photos_bucket)
    blob = bucket.blob(gcs_path)
    if not blob.exists():
        return ''
    return _get_signed_url(blob, minutes)


def delete_conversation_photo(uid: str, image_id: str) -> bool:
    """
    Delete a conversation photo from GCS.

    Args:
        uid: User ID
        image_id: Image identifier

    Returns:
        True if deleted, False if not found
    """
    bucket = storage_client.bucket(conversation_photos_bucket)

    # Try both extensions
    for ext in ['jpg', 'png']:
        path = f'{uid}/{image_id}.{ext}'
        blob = bucket.blob(path)
        if blob.exists():
            blob.delete()
            return True

    return False


def delete_conversation_photo_by_path(gcs_path: str) -> bool:
    """
    Delete a conversation photo by its GCS path.

    Args:
        gcs_path: GCS path (e.g., "uid/image_id.jpg")

    Returns:
        True if deleted, False if not found
    """
    if not gcs_path:
        return False
    bucket = storage_client.bucket(conversation_photos_bucket)
    blob = bucket.blob(gcs_path)
    if blob.exists():
        blob.delete()
        return True
    return False


def conversation_photo_exists(uid: str, image_id: str) -> bool:
    """
    Check if a conversation photo exists in GCS.

    Args:
        uid: User ID
        image_id: Image identifier

    Returns:
        True if exists, False otherwise
    """
    bucket = storage_client.bucket(conversation_photos_bucket)

    for ext in ['jpg', 'png']:
        path = f'{uid}/{image_id}.{ext}'
        blob = bucket.blob(path)
        if blob.exists():
            return True

    return False


def get_conversation_photo_metadata(uid: str, image_id: str) -> dict:
    """
    Get metadata for a conversation photo.

    Args:
        uid: User ID
        image_id: Image identifier

    Returns:
        Dict with size, content_type, created, or empty dict if not found
    """
    bucket = storage_client.bucket(conversation_photos_bucket)

    for ext in ['jpg', 'png']:
        path = f'{uid}/{image_id}.{ext}'
        blob = bucket.blob(path)
        if blob.exists():
            blob.reload()
            return {
                'size': blob.size,
                'content_type': blob.content_type,
                'created': blob.time_created.isoformat() if blob.time_created else None,
                'gcs_path': path,
            }

    return {}

