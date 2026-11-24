import gzip
import hashlib
import json
import os


def sha256_file(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class Artifacts:
    def __init__(self, bucket=None):
        if bucket is None:
            from utils.other.storage import storage_client, memories_recordings_bucket
            bucket = storage_client.bucket(memories_recordings_bucket)
        self.bucket = bucket

    def put_audio(self, job_id, token, path):
        blob = self.bucket.blob(f'audio_jobs/{job_id}/{token}/audio.wav')
        digest = sha256_file(path)
        blob.upload_from_filename(path, if_generation_match=0, timeout=180, checksum='crc32c')
        return {'path': blob.name, 'generation': int(blob.generation), 'sha256': digest,
                'size': os.path.getsize(path)}

    def download_audio(self, audio, path):
        blob = self.bucket.blob(audio['path'], generation=audio['generation'])
        blob.download_to_filename(path, if_generation_match=audio['generation'], timeout=180)
        if sha256_file(path) != audio['sha256']:
            from .state import JobFailure
            raise JobFailure('audio_integrity', retryable=False)

    def put(self, job_id, token, name, value):
        blob = self.bucket.blob(f'audio_jobs/{job_id}/{token}/{name}.json.gz')
        data = gzip.compress(json.dumps(value, ensure_ascii=False, default=str).encode())
        blob.upload_from_string(data, content_type='application/gzip', if_generation_match=0)
        return {'path': blob.name, 'generation': int(blob.generation)}

    def get(self, reference):
        blob = self.bucket.blob(reference['path'], generation=reference['generation'])
        return json.loads(gzip.decompress(blob.download_as_bytes(if_generation_match=reference['generation'])))

    def ensure_playback(self, job):
        from google.api_core.exceptions import PreconditionFailed
        target = f"{job['uid']}/{job['conversation_id']}.wav"
        source = self.bucket.blob(job['audio']['path'], generation=job['audio']['generation'])
        try:
            self.bucket.copy_blob(source, self.bucket, target, if_generation_match=0,
                                  if_source_generation_match=job['audio']['generation'])
        except PreconditionFailed:
            # Only this stable job id writes the playback object. Never overwrite it.
            if not self.bucket.blob(target).exists():
                raise
        return target
