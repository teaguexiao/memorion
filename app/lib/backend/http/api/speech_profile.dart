import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:memorion/backend/schema/speech_profile_info.dart';
import 'package:memorion/backend/schema/speech_sample.dart';
import 'package:memorion/backend/schema/speaker_id_result.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/env/env.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';

/// Get speech profile info (replaces v3/speech-profile and v4/speech-profile)
/// Returns SpeechProfileInfo with has_profile status and profile URL
Future<SpeechProfileInfo?> getSpeechProfile() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/speech-profiles',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('getSpeechProfile: ${response.body}');
  if (response.statusCode == 200) {
    return SpeechProfileInfo.fromJson(jsonDecode(response.body));
  }
  return null;
}

/// Check if user has a speech profile (convenience method)
Future<bool> userHasSpeakerProfile() async {
  var profileInfo = await getSpeechProfile();
  if (profileInfo == null) return true; // Avoid showing banner on error
  return profileInfo.hasProfile;
}

/// Get speech profile URL (convenience method for backward compatibility)
Future<String?> getUserSpeechProfile() async {
  var profileInfo = await getSpeechProfile();
  return profileInfo?.profileUrl;
}

/// Upload speech profile (replaces v3/upload-audio)
/// POST /v1/speech-profiles with multipart audio file
Future<bool> uploadProfile(File file) async {
  var url = appendExternalUserId('${Env.apiBaseUrl}v1/speech-profiles');
  var request = http.MultipartRequest(
    'POST',
    Uri.parse(url),
  );
  request.files.add(await http.MultipartFile.fromPath('audio_file', file.path, filename: basename(file.path)));
  request.headers.addAll({'Authorization': getAuthHeader()});

  try {
    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 201 || response.statusCode == 200) {
      debugPrint('uploadProfile Response body: ${jsonDecode(response.body)}');
      return true;
    } else {
      debugPrint('Failed to upload profile. Status code: ${response.statusCode}, body: ${response.body}');
      throw Exception('Failed to upload profile. Status code: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('An error occurred uploadProfile: $e');
    throw Exception('An error occurred uploadProfile: $e');
  }
}

/// Delete speech profile
/// DELETE /v1/speech-profiles
Future<bool> deleteSpeechProfile() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/speech-profiles',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deleteSpeechProfile: ${response.statusCode}');
  return response.statusCode == 204 || response.statusCode == 200;
}

/// Get expanded profile samples (replaces v3/speech-profile/expand)
/// GET /v1/speech-profiles/samples
/// Returns list of SpeechSample objects
Future<List<SpeechSample>> getSpeechSamples() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/speech-profiles/samples',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  debugPrint('getSpeechSamples: ${response.body}');
  if (response.statusCode == 200) {
    var data = jsonDecode(response.body);
    if (data != null && data is List) {
      return data.map((e) => SpeechSample.fromJson(e)).toList();
    }
  }
  return [];
}

/// Get expanded profile samples as URLs (backward compatibility)
Future<List<String>> getExpandedProfileSamples() async {
  var samples = await getSpeechSamples();
  return samples.map((s) => s.sampleUrl).toList();
}

/// Upload additional speech sample
/// POST /v1/speech-profiles/samples
Future<SpeechSample?> uploadSpeechSample(File file) async {
  var url = appendExternalUserId('${Env.apiBaseUrl}v1/speech-profiles/samples');
  var request = http.MultipartRequest(
    'POST',
    Uri.parse(url),
  );
  request.files.add(await http.MultipartFile.fromPath('audio_file', file.path, filename: basename(file.path)));
  request.headers.addAll({'Authorization': getAuthHeader()});

  try {
    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 201 || response.statusCode == 200) {
      debugPrint('uploadSpeechSample Response body: ${response.body}');
      var data = jsonDecode(response.body);
      return SpeechSample(
        sampleId: data['sample_id'] ?? '',
        sampleUrl: data['sample_url'] ?? '',
        durationSeconds: data['duration_seconds']?.toDouble(),
      );
    } else {
      debugPrint('Failed to upload sample. Status code: ${response.statusCode}');
      throw Exception('Failed to upload sample. Status code: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('An error occurred uploadSpeechSample: $e');
    throw Exception('An error occurred uploadSpeechSample: $e');
  }
}

/// Delete speech sample by ID (replaces v3/speech-profile/expand DELETE)
/// DELETE /v1/speech-profiles/samples/{sample_id}
Future<bool> deleteSpeechSample(String sampleId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/speech-profiles/samples/$sampleId',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deleteSpeechSample: ${response.statusCode}');
  return response.statusCode == 204 || response.statusCode == 200;
}

/// Delete profile sample (backward compatibility - deprecated)
/// Use deleteSpeechSample(sampleId) instead
@Deprecated('Use deleteSpeechSample(sampleId) instead')
Future<bool> deleteProfileSample(
  String conversationId,
  int segmentIdx, {
  String? personId,
}) async {
  // This is kept for backward compatibility but the new API uses sample_id directly
  // The old format extracted sample_id from URL pattern: {conversation_id}_segment_{segment_idx}
  // For new API, caller should use deleteSpeechSample with the actual sample_id
  debugPrint('deleteProfileSample is deprecated. Use deleteSpeechSample with sample_id instead.');
  return false;
}

/// Result of a server-side speaker identification run.
class IdentifySpeakersOutcome {
  final int updatedSegments;
  final bool matched;

  const IdentifySpeakersOutcome({this.updatedSegments = 0, this.matched = false});
}

/// Re-run voiceprint identification on a stored conversation, server-side.
/// POST /v1/conversations/{id}/identify-speakers
///
/// Replaces the old client-side flow (download the recording, POST it to
/// /v1/speaker-identification, write the verdicts back). The client cannot do
/// this correctly: the stored recording has silence trimmed out while our
/// timestamps refer to the untrimmed audio, so slicing it here reads the wrong
/// speaker; and we send no diarization labels, so every segment was compared as
/// if one person spoke the whole conversation. The backend owns both.
Future<IdentifySpeakersOutcome> identifyConversationSpeakers(String conversationId) async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/conversations/$conversationId/identify-speakers',
    headers: {},
    method: 'POST',
    body: '',
  );
  if (response == null) return const IdentifySpeakersOutcome();
  debugPrint('identifyConversationSpeakers: ${response.statusCode} ${response.body}');
  if (response.statusCode != 200) return const IdentifySpeakersOutcome();
  try {
    final data = jsonDecode(response.body);
    return IdentifySpeakersOutcome(
      updatedSegments: (data['updated_segments'] ?? 0) as int,
      matched: (data['matched'] ?? false) as bool,
    );
  } catch (e) {
    debugPrint('identifyConversationSpeakers parse error: $e');
    return const IdentifySpeakersOutcome();
  }
}

/// Identify speakers in audio segments
/// POST /v1/speaker-identification
@Deprecated('Use identifyConversationSpeakers — the client cannot align timestamps ' // i18n-ignore
    'with the trimmed recording or supply diarization labels.') // i18n-ignore
Future<List<SpeakerIdResult>> identifySpeakers(
  File audioFile,
  List<TranscriptSegment> segments,
) async {
  var url = appendExternalUserId('${Env.apiBaseUrl}v1/speaker-identification');
  var request = http.MultipartRequest(
    'POST',
    Uri.parse(url),
  );

  request.files.add(await http.MultipartFile.fromPath('audio_file', audioFile.path, filename: basename(audioFile.path)));

  // Convert segments to JSON format expected by API
  var segmentsJson = segments
      .map((s) => {
            'start': s.start,
            'end': s.end,
            'text': s.text,
          })
      .toList();
  request.fields['segments'] = jsonEncode(segmentsJson);
  request.headers.addAll({'Authorization': getAuthHeader()});

  try {
    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      debugPrint('identifySpeakers Response body: ${response.body}');
      var data = jsonDecode(response.body);
      if (data['results'] != null && data['results'] is List) {
        return (data['results'] as List).map((e) => SpeakerIdResult.fromJson(e)).toList();
      }
    } else {
      debugPrint('Failed to identify speakers. Status code: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('An error occurred identifySpeakers: $e');
  }

  // Return empty/default results on error
  return segments.map((_) => SpeakerIdResult(isUser: false, confidence: 0.0)).toList();
}
