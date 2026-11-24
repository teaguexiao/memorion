"""Resumable Soniox calls. Persist remote IDs; never delete work on a timeout."""
import copy
import os
import time

import requests
from requests_toolbelt.multipart.encoder import MultipartEncoder

from .state import JobFailure


class Soniox:
    def __init__(self, session=None, clock=time.monotonic, sleep=time.sleep):
        self.http = session or requests.Session()
        self.clock, self.sleep = clock, sleep

    def request(self, method, path, **kwargs):
        key = os.environ.get('SONIOX_API_KEY')
        if not key:
            raise JobFailure('provider_auth', retry_after=600)
        headers = {'Authorization': f'Bearer {key}', **kwargs.pop('headers', {})}
        response = self.http.request(method, f'https://api.soniox.com/v1{path}', headers=headers,
                                     timeout=kwargs.pop('timeout', 30), **kwargs)
        if response.status_code >= 400:
            status = response.status_code
            raw_delay = response.headers.get('Retry-After', '0')
            try:
                delay = max(0, float(raw_delay))
            except ValueError:
                from email.utils import parsedate_to_datetime
                try:
                    delay = max(0, parsedate_to_datetime(raw_delay).timestamp() - time.time())
                except (TypeError, ValueError):
                    delay = 0
            if status in (401, 403):
                raise JobFailure('provider_auth', retry_after=600)
            if status == 429:
                raise JobFailure('provider_rate_limit', retry_after=delay)
            if status == 404:
                raise JobFailure('provider_job_missing', retryable=False)
            raise JobFailure('provider_unavailable' if status >= 500 else 'provider_rejected',
                             retryable=status >= 500, retry_after=delay)
        return response

    def transcribe(self, path, language, checkpoint, save):
        from utils.audio_upload_media import needs_transcription_chunks, transcription_chunks
        # Never replace an already submitted legacy job with billable new jobs.
        if not checkpoint.get('soniox_chunks') and (checkpoint.get('soniox_file_id') or
                                                    not needs_transcription_chunks(path)):
            return self._transcribe_one(path, language, checkpoint, save)
        chunks = copy.deepcopy(checkpoint.get('soniox_chunks', {}))
        segments, languages = [], []
        next_speaker = 0
        for index, chunk in enumerate(transcription_chunks(path)):
            key = str(index)
            part = chunks.setdefault(key, {})

            def save_part(values):
                part.update(values)
                save({'soniox_chunks': copy.deepcopy(chunks)})

            result = self._transcribe_one(chunk.path, language, part, save_part, chunk=chunk)
            if not part.get('completed'):
                # Each newly completed part grants the next part a fresh bounded
                # retry budget. Replaying a completed part must NOT reset it.
                part['completed'] = True
                save({'soniox_chunks': copy.deepcopy(chunks)}, 'transcribe')
            speakers = {}
            for segment in result['segments']:
                label = segment['speaker']
                if label not in speakers:
                    speakers[label] = f'SPEAKER_{next_speaker:02d}'
                    next_speaker += 1
                segments.append({**segment, 'speaker': speakers[label]})
            if result['segments']:
                languages.append((len(result['segments']), result['language']))
        if not segments:
            raise JobFailure('no_speech', retryable=False)
        return {'segments': segments, 'language': max(languages, key=lambda item: item[0])[1]}

    def _transcribe_one(self, path, language, checkpoint, save, *, chunk=None):
        from utils.stt.pre_recorded import _soniox_language_hints, _soniox_tokens_to_segments, _detect_language_from_tokens
        cp = dict(checkpoint)
        if not cp.get('soniox_file_id'):
            with open(path, 'rb') as stream:
                multipart = MultipartEncoder(fields={'file': ('audio.wav', stream, 'audio/wav')})
                response = self.request('POST', '/files', data=multipart,
                                        headers={'Content-Type': multipart.content_type}, timeout=180)
            cp['soniox_file_id'] = response.json()['id']
            save({'soniox_file_id': cp['soniox_file_id']})
        if not cp.get('soniox_transcription_id'):
            if cp.get('soniox_submission_pending'):
                # The create request may have succeeded before its response/checkpoint was lost.
                # Do not silently create another billable transcription.
                raise JobFailure('provider_submission_unknown', retryable=False)
            save({'soniox_submission_pending': True})
            try:
                response = self.request('POST', '/transcriptions', json={
                    'model': 'stt-async-v5', 'file_id': cp['soniox_file_id'],
                    'language_hints': _soniox_language_hints(language),
                    'enable_speaker_diarization': True, 'enable_language_identification': True,
                })
            except JobFailure as error:
                # Definite non-acceptance can safely retry. 5xx is ambiguous.
                if error.code in {'provider_auth', 'provider_rate_limit', 'provider_rejected'}:
                    save({'soniox_submission_pending': False})
                raise
            cp['soniox_transcription_id'] = response.json()['id']
            save({'soniox_transcription_id': cp['soniox_transcription_id'], 'soniox_submission_pending': False})
        transcription_id = cp['soniox_transcription_id']
        deadline = self.clock() + 240
        while self.clock() < deadline:
            data = self.request('GET', f'/transcriptions/{transcription_id}').json()
            if data['status'] == 'completed':
                tokens = self.request('GET', f'/transcriptions/{transcription_id}/transcript').json().get('tokens', [])
                if chunk is not None:
                    tokens = chunk.tokens(tokens)
                # Both single-file and chunked uploads retain the full WAV axis.
                # chunk.tokens() has already restored each part's absolute offset.
                segments = _soniox_tokens_to_segments(tokens)
                if not segments and chunk is None:
                    raise JobFailure('no_speech', retryable=False)
                return {'segments': segments, 'language': _detect_language_from_tokens(tokens) or language}
            if data['status'] == 'error':
                raise JobFailure('provider_transcription_failed', retryable=False)
            self.sleep(2)
        raise JobFailure('provider_timeout', retry_after=30)

    def cleanup(self, checkpoint):
        for part in checkpoint.get('soniox_chunks', {}).values():
            self.cleanup(part)
        for key, collection in [('soniox_transcription_id', 'transcriptions'), ('soniox_file_id', 'files')]:
            if checkpoint.get(key):
                try:
                    self.request('DELETE', f'/{collection}/{checkpoint[key]}')
                except JobFailure as error:
                    if error.code != 'provider_job_missing':
                        raise
