import os
import time
from typing import List, Optional, Tuple

import requests as http_requests
from requests_toolbelt.multipart.encoder import MultipartEncoder

from models.transcript_segment import TranscriptSegment


def _soniox_tokens_to_segments(tokens: list, *, normalize: bool = False) -> list:
    """
    Convert Soniox tokens into transcript segments grouped by speaker.
    Merge consecutive tokens from the same speaker; gap > 30s triggers a new segment.
    By default keep the file's audio coordinates, including leading silence.
    The recording, playback, speaker matching and enrollment all use that axis.
    ``normalize=True`` is only for callers producing a display-only transcript.
    """
    if not tokens:
        return []

    segments = []
    for token in tokens:
        raw_text = token.get("text", "")
        # ⚠️ Two different texts on purpose. Soniox carries word boundaries *inside*
        # each token's text (" how", not "how"), exactly like the live streaming path
        # assembles them (`streaming.py` joins raw `token['text']` with no separator).
        # So the stripped form may only be used to decide whether a token is empty and
        # to open a segment; appending it is what glued English transcripts into
        # "Hellohowareyou". Chinese hid this — it has no inter-word spaces.
        text = raw_text.strip()
        if not text:
            continue

        start_ms = token.get("start_ms", 0)
        duration_ms = token.get("duration_ms", 0)
        speaker = token.get("speaker", 0)
        if speaker is None:
            speaker_label = "SPEAKER_00"
        elif isinstance(speaker, int):
            speaker_label = f"SPEAKER_{speaker:02d}"
        else:
            # Soniox async API may return speaker as string
            try:
                speaker_label = f"SPEAKER_{int(speaker):02d}"
            except (ValueError, TypeError):
                speaker_label = f"SPEAKER_{speaker}"

        start_sec = round(start_ms / 1000.0, 2)
        end_sec = round((start_ms + duration_ms) / 1000.0, 2)

        if segments:
            last = segments[-1]
            same_speaker = last["speaker"] == speaker_label
            gap = start_sec - last["end"]
            if same_speaker and gap < 30:
                last["end"] = end_sec
                last["original_end"] = end_sec
                last["text"] += raw_text  # raw: the leading space is the word boundary
                continue

        segments.append({
            "text": text,
            "start": start_sec,
            "end": end_sec,
            "original_start": start_sec,
            "original_end": end_sec,
            "timestamp_axis": 'display' if normalize else 'audio',
            "speaker": speaker_label,
            "is_user": False,
        })

    # Optional display normalization. Never use this for a stored recording:
    # subtracting leading silence without trimming the WAV cuts the wrong voice.
    if segments and normalize:
        offset = segments[0]["start"]
        if offset > 0:
            for seg in segments:
                seg["start"] = round(seg["start"] - offset, 2)
                seg["end"] = round(seg["end"] - offset, 2)

    return segments


def _detect_language_from_tokens(tokens: list) -> Optional[str]:
    """Detect the dominant language from Soniox tokens."""
    if not tokens:
        return None
    lang_counts = {}
    for token in tokens:
        lang = token.get("language")
        if lang:
            lang_counts[lang] = lang_counts.get(lang, 0) + 1
    if not lang_counts:
        return None
    return max(lang_counts, key=lang_counts.get)


#: 默认双语提示。中英混说是本产品的主要形态，而 hints 只是先验、不是白名单
#: （`enable_language_identification` 打开着，说别的语言照样识别）。
_DEFAULT_LANGUAGE_HINTS = ["zh", "en"]

#: 这些值的语义是「没有指定语言」，不是语言码。
#:
#: 🚨 **`multi` 必须在这里面。** 它是**实时**链路的 Soniox 模型名（`stt-rt-v5` 的 multi），
#: 不是 ISO 语言码 —— 而 `POST /v1/conversations/upload-audio` 的 `language` **Query 默认值
#: 就是 `"multi"`**，手表同步路径还显式传它。原来的判据只放过 `"auto"`，于是 `multi` 被原样
#: 当成 hint 发出去，Soniox 回 400 `{"location": "body.payload.language_hints", "message":
#: "Invalid language hint."}`，`audio_upload.py` 把它映射成 502，客户端（正确地）不把 5xx
#: 当永久失败于是无限重试 —— 用户看到的是「同步失败」，而**任何不显式传 language 的上传都
#: 必然失败**，不只是手表（2026-08-15 生产日志确认，同一个文件三次 502）。
_LANGUAGE_SENTINELS = {"auto", "multi", "any", "detect", "auto_detect", "und", "unknown"}


def _soniox_language_hints(language: Optional[str]) -> List[str]:
    """把调用方给的 language 规整成 Soniox 能接受的 `language_hints`。

    ⚠️ **一个认不出来的值必须降级成「没指定」，绝不能原样透传。** hints 是一项优化，
    而 Soniox 对非法 hint 的反应是让**整次转录**失败 —— 让「语言猜错」这种小事有能力毁掉
    一段真录音，是明显不划算的交换。所以这里只放行确实像 ISO 639-1 的两字母码。

    也顺手修掉一个潜伏的同类：原来只把 `zh*` 规整成 `zh`，`en-US` / `zh_CN` 这类带地区的
    码会原样发出去 —— 同样是「Invalid language hint」，只是还没有人这么传过。
    """
    if not language:
        return list(_DEFAULT_LANGUAGE_HINTS)

    hints = []
    # 允许 "zh,en" 这种写法；顺带把空段落掉。
    for raw in str(language).replace(";", ",").split(","):
        token = raw.strip().lower()
        if not token or token in _LANGUAGE_SENTINELS:
            continue
        # zh-CN / zh_Hans / en-US → zh / zh / en
        base = token.replace("_", "-").split("-")[0]
        # ⚠️ `isascii()` 不是多余的：`"中文".isalpha()` 是 **True** 而 `len` 恰好也是 2，
        # 少了它「中文」这个词本身就成了一个合法 hint（测试实测抓到）。
        if len(base) == 2 and base.isascii() and base.isalpha():
            if base not in hints:
                hints.append(base)
        else:
            print(f"[soniox-async] ignoring unrecognized language hint: {raw!r}")

    return hints or list(_DEFAULT_LANGUAGE_HINTS)


def soniox_transcribe_file(
    file_path: str, language: str = "auto", raise_on_error: bool = False
) -> Tuple[List[TranscriptSegment], str]:
    """
    Transcribe a local audio file using Soniox async API (stt-async-v5).
    Returns (transcript_segments, detected_language).

    `raise_on_error` picks the failure mode, and the two callers genuinely need
    different ones:

    - `False` (default) — swallow the error and return `([], "en")`. The SD-card
      batch path depends on this: `sync.transcribe_all` runs up to 480 files and one
      run Soniox can't handle must not cost the batch its other 479.
    - `True` — re-raise. A single-file caller has to be able to tell "Soniox failed"
      from "the audio genuinely had no speech", because otherwise both arrive as an
      empty list and get reported to the user as the same thing — and the wrong one
      of those two tells them to go re-record perfectly good audio.
    """
    soniox_api_key = os.getenv('SONIOX_API_KEY')
    if not soniox_api_key:
        raise ValueError("SONIOX_API_KEY environment variable is not set.")

    soniox_base_url = "https://api.soniox.com/v1"
    soniox_headers = {"Authorization": f"Bearer {soniox_api_key}"}

    soniox_file_id = None
    soniox_transcription_id = None

    try:
        # Step 1: Upload file to Soniox
        print(f"[soniox-async] Uploading file: {file_path}")
        with open(file_path, 'rb') as f:
            # requests' files= buffers the entire WAV and encoded multipart body.
            # A long normalized recording can be ~200 MB; stream both instead.
            multipart = MultipartEncoder(fields={"file": (os.path.basename(file_path), f, 'application/octet-stream')})
            upload_resp = http_requests.post(
                f"{soniox_base_url}/files",
                headers={**soniox_headers, 'Content-Type': multipart.content_type},
                data=multipart,
                timeout=120,
            )
        if upload_resp.status_code not in (200, 201):
            raise Exception(f"Soniox file upload failed: {upload_resp.status_code} {upload_resp.text}")
        soniox_file_id = upload_resp.json()["id"]
        print(f"[soniox-async] File uploaded: {soniox_file_id}")

        # Step 2: Create transcription
        language_hints = _soniox_language_hints(language)

        create_body = {
            "model": "stt-async-v5",
            "file_id": soniox_file_id,
            "language_hints": language_hints,
            "enable_speaker_diarization": True,
            "enable_language_identification": True,
        }
        print(f"[soniox-async] Creating transcription: {create_body}")
        create_resp = http_requests.post(
            f"{soniox_base_url}/transcriptions",
            headers={**soniox_headers, "Content-Type": "application/json"},
            json=create_body,
            timeout=30,
        )
        if create_resp.status_code != 201:
            raise Exception(f"Soniox create transcription failed: {create_resp.status_code} {create_resp.text}")
        soniox_transcription_id = create_resp.json()["id"]
        print(f"[soniox-async] Transcription created: {soniox_transcription_id}")

        # Step 3: Poll until completed
        max_wait_seconds = 300
        poll_interval = 2
        elapsed = 0
        while elapsed < max_wait_seconds:
            status_resp = http_requests.get(
                f"{soniox_base_url}/transcriptions/{soniox_transcription_id}",
                headers=soniox_headers,
                timeout=15,
            )
            if status_resp.status_code != 200:
                raise Exception(f"Soniox status check failed: {status_resp.status_code} {status_resp.text}")
            status_data = status_resp.json()
            status = status_data["status"]
            print(f"[soniox-async] Status: {status} (elapsed: {elapsed}s)")

            if status == "completed":
                break
            elif status == "error":
                raise Exception(status_data.get("error_message", "Soniox transcription failed"))

            time.sleep(poll_interval)
            elapsed += poll_interval

        if elapsed >= max_wait_seconds:
            raise Exception(f"Soniox transcription timed out after {max_wait_seconds}s")

        # Step 4: Get transcript tokens
        transcript_resp = http_requests.get(
            f"{soniox_base_url}/transcriptions/{soniox_transcription_id}/transcript",
            headers=soniox_headers,
            timeout=30,
        )
        if transcript_resp.status_code != 200:
            raise Exception(f"Soniox get transcript failed: {transcript_resp.status_code} {transcript_resp.text}")
        tokens = transcript_resp.json().get("tokens", [])

        # Step 5: Convert tokens to TranscriptSegment objects
        segment_dicts = _soniox_tokens_to_segments(tokens)
        detected_language = _detect_language_from_tokens(tokens) or "en"

        # `.strip()` only — deliberately *not* `.capitalize()`, which this used to do.
        # `str.capitalize()` lower-cases everything after the first character, so
        # "I flew to Paris with John" came out "I flew to paris with john". stt-async-v5
        # already returns cased, punctuated text, and the live streaming path never
        # re-cases it (`streaming.py` joins token text as-is) — so capitalizing here
        # only made offline transcripts worse than real-time ones. It was inherited
        # from the FAL path, whose per-word tokens carried no casing to preserve.
        transcript_segments = [
            TranscriptSegment(
                text=s["text"].strip(),
                speaker=s["speaker"],
                is_user=s["is_user"],
                person_id=None,
                start=s["start"],
                end=s["end"],
                original_start=s['original_start'],
                original_end=s['original_end'],
                timestamp_axis=s['timestamp_axis'],
            )
            for s in segment_dicts
        ]

        return transcript_segments, detected_language

    except Exception as e:
        print(f"[soniox-async] Error: {e}")
        if raise_on_error:
            raise
        return [], "en"

    finally:
        # Cleanup Soniox resources
        try:
            if soniox_transcription_id:
                http_requests.delete(
                    f"{soniox_base_url}/transcriptions/{soniox_transcription_id}",
                    headers=soniox_headers,
                    timeout=10,
                )
                print(f"[soniox-async] Deleted transcription: {soniox_transcription_id}")
        except Exception as e:
            print(f"[soniox-async] Warning: failed to delete transcription: {e}")

        try:
            if soniox_file_id:
                http_requests.delete(
                    f"{soniox_base_url}/files/{soniox_file_id}",
                    headers=soniox_headers,
                    timeout=10,
                )
                print(f"[soniox-async] Deleted file: {soniox_file_id}")
        except Exception as e:
            print(f"[soniox-async] Warning: failed to delete file: {e}")
