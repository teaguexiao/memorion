import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:memorion/backend/preferences.dart';
import 'package:path_provider/path_provider.dart';

/// Model for audio file information used in storage management UI
class AudioFileInfo {
  final String conversationId;
  final String path;
  final int sizeBytes;
  final DateTime modifiedTime;

  AudioFileInfo({
    required this.conversationId,
    required this.path,
    required this.sizeBytes,
    required this.modifiedTime,
  });

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Service for persisting audio files locally for playback in conversation details.
/// Stores audio files in app documents directory: {appDir}/conversation_audio/{conversationId}.wav
class LocalAudioStorage {
  static final LocalAudioStorage _instance = LocalAudioStorage._internal();

  factory LocalAudioStorage() => _instance;

  LocalAudioStorage._internal();

  /// Get the directory for storing conversation audio files
  Future<Directory> _getAudioDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${appDir.path}/conversation_audio');
    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    return audioDir;
  }

  /// Save an audio file for a conversation
  /// Returns the path to the saved file, or null if saving failed
  Future<String?> saveAudioForConversation(String conversationId, File audioFile) async {
    try {
      final audioDir = await _getAudioDirectory();
      final extension = audioFile.path.split('.').last;
      final targetPath = '${audioDir.path}/$conversationId.$extension';

      // Copy the file to the permanent location
      await audioFile.copy(targetPath);

      // Store the mapping in preferences
      final paths = SharedPreferencesUtil().conversationAudioPaths;
      paths[conversationId] = targetPath;
      SharedPreferencesUtil().conversationAudioPaths = paths;

      debugPrint('LocalAudioStorage: Saved audio for conversation $conversationId at $targetPath');
      return targetPath;
    } catch (e) {
      debugPrint('LocalAudioStorage: Error saving audio for conversation $conversationId: $e');
      return null;
    }
  }

  /// Get the audio file path for a conversation
  /// Returns null if no audio is stored for this conversation
  String? getAudioPath(String conversationId) {
    final paths = SharedPreferencesUtil().conversationAudioPaths;
    final path = paths[conversationId];

    // Verify the file still exists
    if (path != null && File(path).existsSync()) {
      return path;
    }

    // Clean up stale reference
    if (path != null) {
      paths.remove(conversationId);
      SharedPreferencesUtil().conversationAudioPaths = paths;
    }

    return null;
  }

  /// Check if audio exists for a conversation
  bool hasAudio(String conversationId) {
    return getAudioPath(conversationId) != null;
  }

  /// Download audio from a URL and cache it locally for a conversation with progress callback.
  /// Used for explicit user-triggered downloads.
  /// Returns the path to the cached file, or null if download failed.
  Future<String?> downloadAndCacheAudioWithProgress(
    String conversationId,
    String audioUrl, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      debugPrint('LocalAudioStorage: Downloading audio with progress for conversation $conversationId from $audioUrl');

      final audioDir = await _getAudioDirectory();
      final targetPath = '${audioDir.path}/$conversationId.wav';

      final client = http.Client();
      final request = http.Request('GET', Uri.parse(audioUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        debugPrint('LocalAudioStorage: Failed to download audio - status ${response.statusCode}');
        client.close();
        return null;
      }

      final contentLength = response.contentLength ?? 0;
      int receivedBytes = 0;
      final bytes = <int>[];

      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        receivedBytes += chunk.length;
        if (contentLength > 0 && onProgress != null) {
          onProgress(receivedBytes / contentLength);
        }
      }

      client.close();

      // Save to local storage
      final file = File(targetPath);
      await file.writeAsBytes(bytes);

      // Store the mapping in preferences
      final paths = SharedPreferencesUtil().conversationAudioPaths;
      paths[conversationId] = targetPath;
      SharedPreferencesUtil().conversationAudioPaths = paths;

      debugPrint('LocalAudioStorage: Downloaded and cached audio for conversation $conversationId at $targetPath');
      return targetPath;
    } catch (e) {
      debugPrint('LocalAudioStorage: Error downloading audio with progress for conversation $conversationId: $e');
      return null;
    }
  }

  /// Download audio from a URL and cache it locally for a conversation.
  /// Used for cloud fallback when local audio is not available (e.g., Developer API uploads).
  /// Returns the path to the cached file, or null if download failed.
  Future<String?> downloadAndCacheAudio(String conversationId, String audioUrl) async {
    try {
      debugPrint('LocalAudioStorage: Downloading audio for conversation $conversationId from $audioUrl');

      final audioDir = await _getAudioDirectory();
      final targetPath = '${audioDir.path}/$conversationId.wav';

      // Download the audio file
      final response = await http.get(Uri.parse(audioUrl));
      if (response.statusCode != 200) {
        debugPrint('LocalAudioStorage: Failed to download audio - status ${response.statusCode}');
        return null;
      }

      // Save to local storage
      final file = File(targetPath);
      await file.writeAsBytes(response.bodyBytes);

      // Store the mapping in preferences
      final paths = SharedPreferencesUtil().conversationAudioPaths;
      paths[conversationId] = targetPath;
      SharedPreferencesUtil().conversationAudioPaths = paths;

      debugPrint('LocalAudioStorage: Downloaded and cached audio for conversation $conversationId at $targetPath');
      return targetPath;
    } catch (e) {
      debugPrint('LocalAudioStorage: Error downloading audio for conversation $conversationId: $e');
      return null;
    }
  }

  /// Delete stored audio for a conversation
  Future<void> deleteAudio(String conversationId) async {
    try {
      final path = getAudioPath(conversationId);
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }

      // Remove from preferences
      final paths = SharedPreferencesUtil().conversationAudioPaths;
      paths.remove(conversationId);
      SharedPreferencesUtil().conversationAudioPaths = paths;

      debugPrint('LocalAudioStorage: Deleted audio for conversation $conversationId');
    } catch (e) {
      debugPrint('LocalAudioStorage: Error deleting audio for conversation $conversationId: $e');
    }
  }

  /// Get total storage used by audio files
  Future<int> getTotalStorageBytes() async {
    try {
      final audioDir = await _getAudioDirectory();
      int totalBytes = 0;

      await for (final entity in audioDir.list()) {
        if (entity is File) {
          totalBytes += await entity.length();
        }
      }

      return totalBytes;
    } catch (e) {
      debugPrint('LocalAudioStorage: Error calculating storage: $e');
      return 0;
    }
  }

  /// Clear all stored audio files
  Future<void> clearAllAudio() async {
    try {
      final audioDir = await _getAudioDirectory();
      await for (final entity in audioDir.list()) {
        if (entity is File) {
          await entity.delete();
        }
      }

      // Clear all mappings
      SharedPreferencesUtil().conversationAudioPaths = {};

      debugPrint('LocalAudioStorage: Cleared all audio files');
    } catch (e) {
      debugPrint('LocalAudioStorage: Error clearing audio files: $e');
    }
  }

  /// Get list of all stored audio files with metadata
  /// Returns list sorted by modification time (newest first)
  Future<List<AudioFileInfo>> getStoredAudioFiles() async {
    final List<AudioFileInfo> files = [];
    final paths = SharedPreferencesUtil().conversationAudioPaths;

    for (final entry in paths.entries) {
      final file = File(entry.value);
      if (await file.exists()) {
        final stat = await file.stat();
        files.add(AudioFileInfo(
          conversationId: entry.key,
          path: entry.value,
          sizeBytes: stat.size,
          modifiedTime: stat.modified,
        ));
      }
    }

    files.sort((a, b) => b.modifiedTime.compareTo(a.modifiedTime));
    return files;
  }
}
