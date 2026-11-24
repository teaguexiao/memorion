import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/services/local_image_storage.dart';

/// Service for caching photos from conversations to local storage.
/// This enables photos to persist after app restart.
class PhotoSyncService {
  static final PhotoSyncService _instance = PhotoSyncService._internal();

  factory PhotoSyncService() => _instance;

  PhotoSyncService._internal();

  final LocalImageStorage _storage = LocalImageStorage();
  final Set<String> _syncingPhotoIds = {};

  /// Cache photos for a list of conversations asynchronously.
  /// This decodes base64 photos and saves them to local storage.
  ///
  /// [conversations] - List of conversations to cache photos from
  /// [onPhotoCached] - Optional callback when a photo is successfully cached
  Future<void> cachePhotosForConversations(
    List<ServerConversation> conversations, {
    void Function(String photoId)? onPhotoCached,
  }) async {
    for (final conversation in conversations) {
      if (conversation.photos.isEmpty) continue;

      for (final photo in conversation.photos) {
        // Skip if already cached or currently syncing
        if (_storage.hasImage(photo.id) || _syncingPhotoIds.contains(photo.id)) {
          continue;
        }

        // Skip if no base64 data
        if (photo.base64.isEmpty) continue;

        _syncingPhotoIds.add(photo.id);
        try {
          // Decode base64 in isolate to avoid blocking UI
          final bytes = await compute(_decodeBase64, photo.base64);
          if (bytes != null && bytes.isNotEmpty) {
            await _storage.saveImageFromBytes(
              photo.id,
              bytes,
              conversationId: conversation.id,
            );
            onPhotoCached?.call(photo.id);
          }
        } catch (e) {
          debugPrint('PhotoSyncService: Error caching photo ${photo.id}: $e');
        } finally {
          _syncingPhotoIds.remove(photo.id);
        }
      }
    }
  }

  /// Decode base64 string to bytes (runs in isolate)
  static Uint8List? _decodeBase64(String base64Data) {
    try {
      return base64Decode(base64Data);
    } catch (e) {
      return null;
    }
  }

  /// Check if a photo is already cached locally
  bool isPhotoCached(String photoId) => _storage.hasImage(photoId);

  /// Check if a photo is currently being synced
  bool isPhotoSyncing(String photoId) => _syncingPhotoIds.contains(photoId);

  /// Get local path for a cached photo
  String? getLocalPath(String photoId) => _storage.getImagePath(photoId);
}
