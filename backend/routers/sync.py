import os
import re
import struct
import tempfile
import threading
from datetime import datetime, timezone
from typing import List

from fastapi import APIRouter, UploadFile, File, Depends, HTTPException
from opuslib import Decoder
from pydub import AudioSegment

# Global lock for opuslib ctypes calls — libopus is not thread-safe
_opus_lock = threading.Lock()

# Serializes `store_segment`'s read-modify-write. Process-local is the right scope
# here: the cross-process case (two ECS tasks handling two sync requests for one
# user at once) is already closed upstream by the per-file claim in
# `retrieve_file_paths` — a given recording's files are only ever handed to one
# request. This lock closes the remaining in-process case, where the same request's
# threads, or a direct `process_segment` caller, would otherwise interleave.
_merge_lock = threading.Lock()

import database.developer_data as dev_db
from models.conversation import Conversation, ConversationSource, CreateConversation
from models.transcript_segment import TranscriptSegment
from utils.conversations.process_conversation import process_conversation, process_conversation_developer
from utils.other import endpoints as auth
from utils.stt.pre_recorded import soniox_transcribe_file
from utils.stt.vad import vad_is_empty

router = APIRouter()

import shutil
import wave


def decode_opus_file_to_wav(opus_file_path, wav_file_path, sample_rate=16000, channels=1, frame_size: int = 160):
    with _opus_lock:
        decoder = Decoder(sample_rate, channels)
    with open(opus_file_path, 'rb') as f:
        pcm_data = []
        frame_count = 0
        while True:
            length_bytes = f.read(4)
            if not length_bytes:
                print("End of file reached.")
                break
            if len(length_bytes) < 4:
                print("Incomplete length prefix at the end of the file.")
                break

            frame_length = struct.unpack('<I', length_bytes)[0]
            # print(f"Reading frame {frame_count}: length {frame_length}")
            opus_data = f.read(frame_length)
            if len(opus_data) < frame_length:
                print(f"Unexpected end of file at frame {frame_count}.")
                break
            try:
                with _opus_lock:
                    pcm_frame = decoder.decode(opus_data, frame_size=frame_size)
                pcm_data.append(pcm_frame)
                frame_count += 1
            except Exception as e:
                print(f"Error decoding frame {frame_count}: {e}")
                break
        if pcm_data:
            pcm_bytes = b''.join(pcm_data)
            with wave.open(wav_file_path, 'wb') as wav_file:
                wav_file.setnchannels(channels)
                wav_file.setsampwidth(2)  # 16-bit audio
                wav_file.setframerate(sample_rate)
                wav_file.writeframes(pcm_bytes)
            print(f"Decoded audio saved to {wav_file_path}")
        else:
            print("No PCM data was decoded.")


def get_timestamp_from_path(path: str):
    timestamp = int(path.split('/')[-1].split('_')[-1].split('.')[0])
    if timestamp > 1e10:
        return timestamp // 1000
    return timestamp


def retrieve_file_paths(files: List[UploadFile], uid: str, developer_id: str, directory: str, claimed: list):
    """Claim and stage each file in the current request's temporary directory."""
    paths = []
    skipped = []
    for file in files:
        filename = file.filename
        if not filename or any(char in filename for char in ('/', '\\', '\0')) or not filename.endswith('.bin'):
            raise HTTPException(status_code=400, detail="Expected a .bin filename")
        if '_' not in filename:
            raise HTTPException(status_code=400, detail="Missing file timestamp")
        try:
            recorded_at = datetime.fromtimestamp(get_timestamp_from_path(filename))
        except (ValueError, OverflowError, OSError):
            raise HTTPException(status_code=400, detail="Invalid file timestamp")
        if recorded_at > datetime.now() or recorded_at < datetime(2024, 1, 1):
            raise HTTPException(status_code=400, detail="Invalid file timestamp")

        if not dev_db.claim_synced_file(developer_id, uid, filename):
            skipped.append(filename)
            continue

        claimed.append(filename)
        path = os.path.join(directory, filename)
        with open(path, 'wb') as buffer:
            shutil.copyfileobj(file.file, buffer)
        paths.append(path)
    return paths, skipped


def decode_files_to_wav(files_path: List[str]):
    wav_files = []
    for path in files_path:
        wav_path = os.path.splitext(path)[0] + '.wav'
        filename = os.path.basename(path)
        frame_size = 160  # Default frame size
        match = re.search(r'_fs(\d+)', filename)
        if match:
            try:
                frame_size = int(match.group(1))
                print(f"Found frame size {frame_size} in filename: {filename}")
            except ValueError:
                print(f"Invalid frame size format in filename: {filename}, using default {frame_size}")

        decode_opus_file_to_wav(path, wav_path, frame_size=frame_size)
        try:
            aseg = AudioSegment.from_wav(wav_path)
        except Exception as e:
            print(f"Unable to decode sync audio: {type(e).__name__}")
            raise HTTPException(status_code=400, detail="Invalid recording data")

        if aseg.duration_seconds < 1:
            os.remove(wav_path)
            continue
        wav_files.append(wav_path)
        os.remove(path)
    return wav_files


MERGE_VOICE_SEGMENTS_SECONDS = 120

# A gap this long between consecutive files means they are not one recording:
# the device was off, or these are two separate sessions that happen to be in the
# same upload batch. Stitching across it would invent audio that never existed.
# Anything shorter is treated as contiguous — the device writes back-to-back
# chunks, so a small gap is a rounding artifact of the byte-count-derived
# timestamps, not real silence.
STITCH_MAX_GAP_SECONDS = 5

# How many voice runs to transcribe at once. Bounded because Soniox rate-limits per
# account, so this budget is shared with every other user syncing at the same moment
# and with the live streaming path.
TRANSCRIBE_CONCURRENCY = 5


def stitch_contiguous_files(wav_paths: List[str]):
    """Group consecutive-in-time wav files into runs, and concatenate each run.

    Returns a list of `(stitched_path, start_timestamp)`.

    **Why this exists**: the device slices audio into fixed ~60s chunks. Those
    boundaries are a transmission artifact with no relation to speech — a sentence
    that happens to straddle one gets cut in half. Running VAD and transcription
    per file (the previous behaviour: one thread per file) therefore split
    utterances at every chunk boundary and asked the STT to transcribe half a
    word. Stitching first means VAD sees the real silence structure and the
    transcriber sees whole sentences.

    Files are ordered by their filename timestamp, never by upload/arrival order:
    the app uploads in reverse (`syncAll` walks batches from the newest backwards)
    and files within a batch complete out of order.
    """
    if not wav_paths:
        return []

    dated = []
    for path in wav_paths:
        try:
            timestamp = get_timestamp_from_path(path)
        except (ValueError, IndexError):
            # Shouldn't happen — `retrieve_file_paths` already validated the name.
            print(f'[sync] cannot read timestamp from {path}, treating it as its own run')
            timestamp = None
        try:
            duration = AudioSegment.from_wav(path).duration_seconds
        except Exception as e:
            print(f'[sync] cannot measure {path}: {e}')
            duration = None
        dated.append((timestamp, path, duration))

    # Order by recording time, never by arrival order: the app uploads batches
    # newest-first and files within a batch finish out of order, so arrival order
    # would stitch the audio backwards. Unreadable timestamps sort last and each
    # becomes its own run rather than being glued in at the wrong point in time.
    dated.sort(key=lambda item: (item[0] is None, item[0]))

    runs: List[List[tuple]] = []
    for entry in dated:
        timestamp, _path, _duration = entry
        if timestamp is None or not runs:
            runs.append([entry])
            continue
        prev_ts, _prev_path, prev_duration = runs[-1][-1]
        if prev_ts is None or prev_duration is None:
            runs.append([entry])
            continue
        gap = timestamp - (prev_ts + prev_duration)
        # `abs`, because the gap can come out slightly negative: these timestamps
        # are derived from byte counts, so they carry rounding error in both
        # directions. A *large* negative gap is different in kind — the files
        # genuinely overlap, i.e. the same audio was captured twice — and must
        # not be concatenated, or the duplicate gets doubled into one track.
        # Splitting the run leaves it to the chapter layer's content dedup.
        if abs(gap) <= STITCH_MAX_GAP_SECONDS:
            runs[-1].append(entry)
        else:
            runs.append([entry])

    stitched = []
    for run in runs:
        start_timestamp, first_path, _ = run[0]
        if len(run) == 1:
            stitched.append((first_path, start_timestamp))
            continue

        combined = AudioSegment.empty()
        for _, path, _ in run:
            combined += AudioSegment.from_wav(path)

        path_dir = os.path.dirname(first_path) or '.'
        # The name carries the run's length as well as its start, and the timestamp
        # stays last so `get_timestamp_from_path` still reads the anchor out of it.
        #
        # The length is there because `vad_is_empty(cache=True)` keys its Redis cache
        # on the file path. A retry after a partial failure can re-stitch the same
        # start timestamp from fewer files — one chunk lost in transit — and a
        # start-only name would then hit the cache and return the *previous*, longer
        # track's speech segments. pydub clamps slices past the end silently, so the
        # symptom would be a truncated or empty cut, not an error.
        out_path = f'{path_dir}/stitched{int(combined.duration_seconds * 1000)}_{start_timestamp}.wav'
        combined.export(out_path, format='wav')
        for _, path, _ in run:
            try:
                os.remove(path)
            except OSError:
                pass
        print(f'[sync] stitched {len(run)} files into {out_path} ({combined.duration_seconds:.1f}s)')
        stitched.append((out_path, start_timestamp))

    return stitched


def retrieve_vad_segments(path: str, segmented_paths: set):
    start_timestamp = get_timestamp_from_path(path)
    voice_segments = vad_is_empty(path, return_segments=True, cache=True)

    segments = []
    # should we merge more aggressively, to avoid too many small segments? ~ not for now
    # Pros -> lesser segments, faster, less concurrency
    # Cons -> less accuracy.

    # edge case, multiple small segments that map towards the same memory .-.
    # so ... let's merge them if distance < 120 seconds
    # a better option would be to keep here 1s, and merge them like that after transcribing
    # but FAL has 10 RPS limit, **let's merge it here for simplicity for now**

    for i, segment in enumerate(voice_segments):
        if segments and (segment['start'] - segments[-1]['end']) < MERGE_VOICE_SEGMENTS_SECONDS:
            segments[-1]['end'] = segment['end']
        else:
            segments.append(segment)

    print(path, segments)

    aseg = AudioSegment.from_wav(path)
    # `or '.'` — `os.path.dirname` returns '' for a bare filename, and f-stringing
    # that would write the cut to the filesystem root instead of next to its source.
    path_dir = os.path.dirname(path) or '.'
    for i, segment in enumerate(segments):
        if (segment['end'] - segment['start']) < 1:
            continue
        segment_timestamp = start_timestamp + segment['start']
        # Prefixed with the run's own start so two runs can't name a cut the same
        # thing. They can: `stitch_contiguous_files` deliberately splits genuinely
        # overlapping files into separate runs, and two overlapping runs can put a cut
        # at the same absolute second. Without the prefix that collision is silent
        # twice over — the export overwrites the earlier file, and `segmented_paths`
        # is a set so the duplicate key drops one cut entirely. The trailing
        # `_{timestamp}` is what `get_timestamp_from_path` reads, so the anchor is
        # unaffected by the prefix.
        segment_path = f'{path_dir}/seg{start_timestamp}_{segment_timestamp}.wav'
        segment_aseg = aseg[segment['start'] * 1000 : segment['end'] * 1000]
        segment_aseg.export(segment_path, format='wav')
        segmented_paths.add(segment_path)


def _merge_into_existing(
    developer_id: str,
    uid: str,
    closest_memory: dict,
    transcript_segments: List[TranscriptSegment],
    timestamp: int,
    response: dict,
    resummarize_ids: set,
):
    """Append newly transcribed segments to an existing conversation.

    Two things this must do that the previous version didn't:

    **Drop segments that are already there.** The previous code concatenated
    unconditionally, so any retransmit or overlapping capture appended a second
    copy of the same sentences. Matching is on `(rounded start, text)` rather than
    text similarity: these are literally the same segment re-derived from the same
    audio, so the text is identical and only float rounding differs.

    **Flag the summary as stale.** It used to write only `transcript_segments`,
    leaving `structured` describing an earlier, shorter transcript. That desync is
    invisible in the API (both fields read fine on their own) and permanent —
    nothing recomputes a summary after the fact. Anything reading the summary
    (chapter rollup, memories, PDP) then works from a stale version of the
    conversation. The regeneration itself is deferred to
    `resummarize_merged_conversations`; see the comment at the end of this function.
    """
    existing = list(closest_memory.get('transcript_segments') or [])
    anchor = closest_memory['started_at'].timestamp()

    seen = {(round(float(seg.get('start', 0.0)), 1), (seg.get('text') or '').strip()) for seg in existing}

    incoming = []
    for seg in transcript_segments:
        seg_dict = seg.dict()
        # Rebase onto the existing conversation's anchor before comparing, so the
        # two sides are on the same axis.
        duration = seg_dict['end'] - seg_dict['start']
        seg_dict['start'] = (timestamp + seg_dict['start']) - anchor
        seg_dict['end'] = seg_dict['start'] + duration
        # This run's file is distinct from the existing conversation recording.
        # Its local coordinates cannot prove a cut on the combined timeline.
        seg_dict.pop('original_start', None)
        seg_dict.pop('original_end', None)
        seg_dict['timestamp_axis'] = 'display'
        key = (round(seg_dict['start'], 1), (seg_dict.get('text') or '').strip())
        if key in seen:
            continue
        seen.add(key)
        incoming.append(seg_dict)

    if not incoming:
        print(f"[sync] nothing new to merge into {closest_memory['id']}, skipping")
        return

    segments = existing + incoming
    segments.sort(key=lambda s: s['start'])

    dev_db.update_conversation_segments_dev(developer_id, uid, closest_memory['id'], segments)
    response['updated_memories'].add(closest_memory['id'])
    # Record that this conversation needs a fresh summary, but don't run it here.
    # A batch can merge many runs into one conversation, and re-summarizing on each
    # would spend N LLM calls to produce N-1 throwaway summaries. It would also be
    # unsafe: `process_conversation_developer` ends with a whole-document upsert
    # built from the transcript it read at entry, so a re-summary still running when
    # the next merge lands would write that stale transcript back over it.
    resummarize_ids.add(closest_memory['id'])


def resummarize_merged_conversations(developer_id: str, uid: str, conversation_ids, language: str):
    """Regenerate summaries for conversations that gained segments in this batch.

    Runs after all merges, once per conversation. Without this the transcript and
    `structured` disagree permanently: nothing recomputes a summary after the fact,
    so every downstream reader (chapter rollup, memories, PDP) works from a summary
    describing a shorter transcript than the one stored.
    """
    for conversation_id in conversation_ids:
        try:
            merged = dev_db.get_conversation(developer_id, uid, conversation_id, include_photos=False)
            if not merged:
                continue
            merged['source'] = _coerce_source(merged.get('source'))
            if not merged.get('structured'):
                merged['structured'] = {'title': '', 'overview': ''}
            conversation = Conversation(**merged)
            # `force_process=True` skips the discard check. The conversation already
            # exists and the user can already see it, so letting the check decide
            # mid-life that it is discardable would remove visible content.
            process_conversation_developer(
                developer_id, uid, merged.get('language') or language, conversation, force_process=True
            )
        except Exception as e:
            # Segments are already persisted. A failed re-summary leaves the
            # conversation exactly as the old code left it — stale summary, intact
            # transcript — rather than losing audio.
            print(f'[sync] failed to re-summarize {conversation_id} after merge: {e}')


def _coerce_source(source_str) -> ConversationSource:
    try:
        return ConversationSource(source_str)
    except ValueError:
        return ConversationSource.sdcard


def transcribe_segment(path: str, transcripts: dict):
    """Transcribe one voice run. Pure network work — safe to run concurrently.

    Kept separate from the merge below on purpose. Transcription is the slow,
    IO-bound, embarrassingly parallel part; the merge is a read-modify-write that
    must be serial. Doing both inside one thread meant either giving up the
    parallelism or racing on the write.
    """
    try:
        transcript_segments, language = soniox_transcribe_file(path)
    except Exception as e:
        print(f'[sync] transcription failed for {path}: {e}')
        return
    if not transcript_segments:
        print('failed to get soniox segments')
        return
    transcripts[path] = (transcript_segments, language)


def transcribe_all(paths: List[str], transcripts: dict):
    """Transcribe every voice run, `TRANSCRIBE_CONCURRENCY` at a time.

    A sliding pool rather than fixed batches: batching joins the whole group before
    starting the next one, so every round costs the slowest call in it and the other
    workers sit idle. With 480 files (8h of audio) that difference is the whole
    endpoint's latency.

    Failures are swallowed by `transcribe_segment` on purpose — one run that Soniox
    can't handle must not cost the batch its other 479. The path simply never appears
    in `transcripts`, so the caller stores nothing for it, and its file keeps its
    claim released by the endpoint's `except`.
    """
    if not paths:
        return
    pending = list(paths)
    lock = threading.Lock()

    def worker():
        while True:
            with lock:
                if not pending:
                    return
                path = pending.pop(0)
            transcribe_segment(path, transcripts)

    threads = [threading.Thread(target=worker) for _ in range(min(TRANSCRIBE_CONCURRENCY, len(pending)))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


def process_segment(path: str, uid: str, response: dict, developer_id: str = None):
    """Transcribe, store, and re-summarize one voice run.

    A single-call entry point for callers outside the batch endpoint. The endpoint
    splits these phases so transcriptions overlap while writes stay serial and each
    conversation is re-summarized once.
    """
    transcripts = {}
    transcribe_segment(path, transcripts)
    if path not in transcripts:
        return
    transcript_segments, language = transcripts[path]
    resummarize_ids = set()
    store_segment(
        path, transcript_segments, language, uid, response,
        developer_id=developer_id, resummarize_ids=resummarize_ids,
    )
    if resummarize_ids:
        resummarize_merged_conversations(developer_id, uid, resummarize_ids, language)


def store_segment(
    path: str,
    transcript_segments: List[TranscriptSegment],
    language: str,
    uid: str,
    response: dict,
    developer_id: str = None,
    resummarize_ids: set = None,
):
    """Attach an already-transcribed run to a conversation. Serialized on `_merge_lock`.

    `get_closest_conversation_to_timestamps` matches on a ±2min window, so several
    runs of one recording routinely resolve to the *same* conversation. The previous
    code ran this on concurrent threads with no lock, each reading the transcript,
    appending its own part, and writing the whole list back — last writer won and
    every other thread's segments were silently dropped. That is a strong candidate
    for the 12.4% timeline overlap measured in Phase 0.

    Creating a conversation races the same way: two runs seconds apart both find
    nothing and each create one, which is exactly the duplicate-conversation shape
    already fixed on the live path.

    The lock lives here rather than at the call site so the invariant can't be lost
    by a future caller: the batch endpoint already calls this from a serial loop, and
    an uncontended `threading.Lock` costs nothing, so making it unconditional is free
    insurance. It deliberately does *not* wrap transcription (slow, parallel-safe) or
    the re-summary (deferred to one call per conversation). Conversation *creation*
    does run under it, LLM and all — the check and the create have to be atomic or the
    race is still there, and since the batch path is serial anyway this costs no
    wall-clock.
    """
    if not developer_id:
        print('store_segment: developer_id is required')
        return

    if resummarize_ids is None:
        resummarize_ids = set()

    timestamp = get_timestamp_from_path(path)

    with _merge_lock:
        closest_memory = dev_db.get_closest_conversation_to_timestamps(
            developer_id, uid, timestamp, timestamp + transcript_segments[-1].end
        )

        if closest_memory:
            _merge_into_existing(
                developer_id, uid, closest_memory, transcript_segments, timestamp, response, resummarize_ids
            )
            return

        create_memory = CreateConversation(
            # `tz=timezone.utc`, not bare `fromtimestamp`. The bare form returns a
            # *naive server-local* datetime, which Firestore then stores as if it
            # were UTC — so on any host not running in UTC every batch-synced
            # recording lands hours off, and this is the anchor from which the
            # timeline derives every segment's absolute time
            # (`started_at + segment.start`). Nothing reports it: the conversation
            # reads fine on its own, only the day's timeline is wrong. Production
            # containers happen to run UTC today, which is exactly what makes this
            # the kind of bug that surfaces later, somewhere else.
            started_at=datetime.fromtimestamp(timestamp, tz=timezone.utc),
            finished_at=datetime.fromtimestamp(timestamp + transcript_segments[-1].end, tz=timezone.utc),
            transcript_segments=transcript_segments,
            # `CreateConversation.source` defaults to `omi`, which here would be a
            # lie with consequences: `omi` means "migrated from upstream Omi, 2026-02
            # and earlier", and several places branch on it. The chapter layer in
            # particular treats `omi` as a real-time source whose boundaries came from
            # physical silence and must never be split, while a batch-synced file's
            # boundaries are pure transmission artifacts that *should* be split on
            # internal silence (`utils/timeline/chaptering._splittable`).
            source=ConversationSource.sdcard,
        )
        created = process_conversation(uid, language, create_memory, developer_id=developer_id)
        response['new_memories'].add(created.id)


@router.post("/v1/sync-local-files")
def sync_local_files(files: List[UploadFile] = File(...), ctx: tuple = Depends(auth.get_current_user_context)):
    """Ingest a batch of SD-card `.bin` files: decode → stitch → VAD → STT → summarize.

    ⚠️ Sync `def` on purpose — see the note on
    `developer_conversations.process_conversation`. This is the single longest
    request the API serves (decode + Silero VAD + Soniox + one LLM pass per run),
    and as `async def` with a fully blocking body it ran all of that on the event
    loop, freezing every other request on the same ECS task for minutes.

    Reading the uploads stays legal here because both this handler and
    `retrieve_file_paths` go through `file.file` (the underlying spooled temp file)
    with `shutil.copyfileobj` — never `await file.read()`, which is what would force
    this back to `async def`.
    """
    developer_id, uid = ctx
    claimed = []
    try:
        with tempfile.TemporaryDirectory(prefix='memorion-sync-') as directory:
            paths, skipped = retrieve_file_paths(files, uid, developer_id, directory, claimed)
            response = {'updated_memories': set(), 'new_memories': set(), 'skipped_files': skipped}
            if not paths:
                return response

            wav_paths = decode_files_to_wav(paths)

            # Stitch first, VAD second. The device's ~60s file boundaries are a
            # transmission artifact, so running VAD per file cut every utterance that
            # crossed one in half. VAD now runs once per contiguous run of audio and
            # sees the real silence structure.
            stitched = stitch_contiguous_files(wav_paths)
            print(f'sync_local_files stitched {len(wav_paths)} files into {len(stitched)} runs')

            segmented_paths = set()
            # VAD is deliberately sequential: `get_speech_segments` serializes on
            # `_vad_lock` anyway (a shared Silero model — concurrent inference corrupts
            # its RNN state and crashes the process), so threads here only added
            # scheduling overhead and the illusion of parallelism.
            for path, _start_timestamp in stitched:
                retrieve_vad_segments(path, segmented_paths)

            print('sync_local_files len(segmented_paths)', len(segmented_paths))

            # Phase 1 — transcribe concurrently. Pure network IO, no shared state
            # beyond `transcripts`, whose only mutation is one key assignment per
            # thread (safe under the GIL). Fed in recording order so that if the pool
            # is smaller than the work, the earliest audio finishes first.
            transcripts = {}
            transcribe_all(sorted(segmented_paths, key=get_timestamp_from_path), transcripts)

            # Phase 2 — write sequentially, in recording order. Serial because each
            # store is a read-modify-write against a conversation several runs may
            # share; in *time* order because a run that arrives first must not become
            # the anchor for audio that was recorded before it.
            resummarize_ids = set()
            for path in sorted(transcripts, key=get_timestamp_from_path):
                transcript_segments, language = transcripts[path]
                store_segment(
                    path, transcript_segments, language, uid, response,
                    developer_id=developer_id, resummarize_ids=resummarize_ids,
                )

            # Phase 3 — one summary per conversation that actually changed. The language
            # passed here is only a last resort: each conversation's own stored `language`
            # wins inside, and it is the more trustworthy value (it came from the whole
            # original recording, not from whichever run of this batch happened to be
            # detected first).
            if resummarize_ids:
                fallback_language = next(iter(transcripts.values()))[1] if transcripts else 'en'
                print(f'sync_local_files re-summarizing {len(resummarize_ids)} merged conversations')
                resummarize_merged_conversations(developer_id, uid, resummarize_ids, fallback_language)
    except Exception:
        # The claim is only valid if the audio actually got processed. Leaving it in
        # place after a failure would make this file permanently unclaimable: the app
        # retries, the backend skips it, and that recording is silently lost forever.
        # A duplicate is recoverable (chapter-level dedup); lost audio is not.
        for filename in claimed:
            dev_db.release_synced_file_claim(developer_id, uid, filename)
        raise

    return response
