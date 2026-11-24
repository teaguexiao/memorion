import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:path_provider/path_provider.dart';

/// Model for image file information used in storage management UI
class ImageFileInfo {
  final String imageId;
  final String path;
  final int sizeBytes;
  final DateTime modifiedTime;
  final String? conversationId;

  ImageFileInfo({
    required this.imageId,
    required this.path,
    required this.sizeBytes,
    required this.modifiedTime,
    this.conversationId,
  });

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Service for persisting image files locally from hardware device captures.
/// Stores image files in app documents directory: {appDir}/conversation_images/{imageId}.jpg
class LocalImageStorage {
  static final LocalImageStorage _instance = LocalImageStorage._internal();

  factory LocalImageStorage() => _instance;

  LocalImageStorage._internal();

  /// Get the directory for storing conversation image files
  Future<Directory> _getImageDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final imageDir = Directory('${appDir.path}/conversation_images');
    if (!await imageDir.exists()) {
      await imageDir.create(recursive: true);
    }
    return imageDir;
  }

  /// Save an image from bytes for a conversation
  /// Returns the path to the saved file, or null if saving failed
  Future<String?> saveImageFromBytes(
    String imageId,
    Uint8List imageBytes, {
    String? conversationId,
  }) async {
    try {
      final imageDir = await _getImageDirectory();
      final targetPath = '${imageDir.path}/$imageId.jpg';

      // Write the bytes to file
      final file = File(targetPath);
      await file.writeAsBytes(imageBytes);

      // Store the mapping in preferences
      final paths = SharedPreferencesUtil().conversationImagePaths;
      paths[imageId] = targetPath;
      SharedPreferencesUtil().conversationImagePaths = paths;

      // Store conversation association if provided
      if (conversationId != null) {
        final associations = SharedPreferencesUtil().imageConversationAssociations;
        associations[imageId] = conversationId;
        SharedPreferencesUtil().imageConversationAssociations = associations;
      }

      debugPrint('LocalImageStorage: Saved image $imageId at $targetPath');
      return targetPath;
    } catch (e) {
      debugPrint('LocalImageStorage: Error saving image $imageId: $e');
      return null;
    }
  }

  /// Save an image file for a conversation
  /// Returns the path to the saved file, or null if saving failed
  Future<String?> saveImageFile(
    String imageId,
    File imageFile, {
    String? conversationId,
  }) async {
    try {
      final imageDir = await _getImageDirectory();
      final extension = imageFile.path.split('.').last;
      final targetPath = '${imageDir.path}/$imageId.$extension';

      // Copy the file to the permanent location
      await imageFile.copy(targetPath);

      // Store the mapping in preferences
      final paths = SharedPreferencesUtil().conversationImagePaths;
      paths[imageId] = targetPath;
      SharedPreferencesUtil().conversationImagePaths = paths;

      // Store conversation association if provided
      if (conversationId != null) {
        final associations = SharedPreferencesUtil().imageConversationAssociations;
        associations[imageId] = conversationId;
        SharedPreferencesUtil().imageConversationAssociations = associations;
      }

      debugPrint('LocalImageStorage: Saved image $imageId at $targetPath');
      return targetPath;
    } catch (e) {
      debugPrint('LocalImageStorage: Error saving image $imageId: $e');
      return null;
    }
  }

  /// Get the image file path for an image ID
  /// Returns null if no image is stored for this ID
  String? getImagePath(String imageId) {
    final paths = SharedPreferencesUtil().conversationImagePaths;
    final path = paths[imageId];

    // Verify the file still exists
    if (path != null && File(path).existsSync()) {
      return path;
    }

    // Clean up stale reference
    if (path != null) {
      paths.remove(imageId);
      SharedPreferencesUtil().conversationImagePaths = paths;

      // Also clean up conversation association
      final associations = SharedPreferencesUtil().imageConversationAssociations;
      associations.remove(imageId);
      SharedPreferencesUtil().imageConversationAssociations = associations;
    }

    return null;
  }

  /// Get the image bytes for an image ID
  /// Returns null if no image is stored or file doesn't exist
  Future<Uint8List?> getImageBytes(String imageId) async {
    final path = getImagePath(imageId);
    if (path == null) return null;

    try {
      final file = File(path);
      return await file.readAsBytes();
    } catch (e) {
      debugPrint('LocalImageStorage: Error reading image $imageId: $e');
      return null;
    }
  }

  /// Check if image exists for an ID
  bool hasImage(String imageId) {
    return getImagePath(imageId) != null;
  }

  /// Get conversation ID associated with an image
  String? getConversationId(String imageId) {
    final associations = SharedPreferencesUtil().imageConversationAssociations;
    return associations[imageId];
  }

  /// Delete stored image
  Future<void> deleteImage(String imageId) async {
    try {
      final path = getImagePath(imageId);
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }

      // Remove from preferences
      final paths = SharedPreferencesUtil().conversationImagePaths;
      paths.remove(imageId);
      SharedPreferencesUtil().conversationImagePaths = paths;

      // Remove conversation association
      final associations = SharedPreferencesUtil().imageConversationAssociations;
      associations.remove(imageId);
      SharedPreferencesUtil().imageConversationAssociations = associations;

      debugPrint('LocalImageStorage: Deleted image $imageId');
    } catch (e) {
      debugPrint('LocalImageStorage: Error deleting image $imageId: $e');
    }
  }

  /// Get total storage used by image files
  Future<int> getTotalStorageBytes() async {
    try {
      final imageDir = await _getImageDirectory();
      int totalBytes = 0;

      await for (final entity in imageDir.list()) {
        if (entity is File) {
          totalBytes += await entity.length();
        }
      }

      return totalBytes;
    } catch (e) {
      debugPrint('LocalImageStorage: Error calculating storage: $e');
      return 0;
    }
  }

  /// Get total number of stored images
  Future<int> getImageCount() async {
    try {
      final imageDir = await _getImageDirectory();
      int count = 0;

      await for (final entity in imageDir.list()) {
        if (entity is File) {
          count++;
        }
      }

      return count;
    } catch (e) {
      debugPrint('LocalImageStorage: Error counting images: $e');
      return 0;
    }
  }

  /// Clear all stored image files
  Future<void> clearAllImages() async {
    try {
      final imageDir = await _getImageDirectory();
      await for (final entity in imageDir.list()) {
        if (entity is File) {
          await entity.delete();
        }
      }

      // Clear all mappings
      SharedPreferencesUtil().conversationImagePaths = {};
      SharedPreferencesUtil().imageConversationAssociations = {};

      debugPrint('LocalImageStorage: Cleared all image files');
    } catch (e) {
      debugPrint('LocalImageStorage: Error clearing image files: $e');
    }
  }

  /// Get list of all stored image files with metadata
  /// Returns list sorted by modification time (newest first)
  Future<List<ImageFileInfo>> getStoredImageFiles() async {
    final List<ImageFileInfo> files = [];
    final paths = SharedPreferencesUtil().conversationImagePaths;
    final associations = SharedPreferencesUtil().imageConversationAssociations;

    for (final entry in paths.entries) {
      final file = File(entry.value);
      if (await file.exists()) {
        final stat = await file.stat();
        files.add(ImageFileInfo(
          imageId: entry.key,
          path: entry.value,
          sizeBytes: stat.size,
          modifiedTime: stat.modified,
          conversationId: associations[entry.key],
        ));
      }
    }

    files.sort((a, b) => b.modifiedTime.compareTo(a.modifiedTime));
    return files;
  }

  /// Get images for a specific conversation
  Future<List<ImageFileInfo>> getImagesForConversation(String conversationId) async {
    final allImages = await getStoredImageFiles();
    return allImages.where((img) => img.conversationId == conversationId).toList();
  }

  /// Delete all images for a specific conversation
  Future<void> deleteImagesForConversation(String conversationId) async {
    final images = await getImagesForConversation(conversationId);
    for (final image in images) {
      await deleteImage(image.imageId);
    }
    debugPrint('LocalImageStorage: Deleted ${images.length} images for conversation $conversationId');
  }

  /// Load all stored photos as ConversationPhoto objects for UI display
  /// Only returns photos that are not yet associated with a conversation
  /// (associated photos have already been synced to the server)
  Future<List<ConversationPhoto>> loadStoredPhotosAsConversationPhotos({bool unassociatedOnly = true}) async {
    final List<ConversationPhoto> photos = [];
    final imageFiles = await getStoredImageFiles();
    final associations = SharedPreferencesUtil().imageConversationAssociations;

    for (final imageFile in imageFiles) {
      // Skip photos that are already associated with a conversation
      if (unassociatedOnly) {
        final convId = associations[imageFile.imageId];
        if (convId != null && convId.isNotEmpty) {
          continue;
        }
      }

      photos.add(ConversationPhoto.fromLocalStorage(
        id: imageFile.imageId,
        localPath: imageFile.path,
        createdAt: imageFile.modifiedTime,
      ));
    }

    debugPrint('LocalImageStorage: Loaded ${photos.length} persisted photos');
    return photos;
  }
}
