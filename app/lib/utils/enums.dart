enum RecordingState { initialising, record, stop, deviceRecord, pause, error }

/// Recording mode determines how audio is processed
enum RecordingMode {
  /// Real-time streaming via WebSocket (default)
  realtime,

  /// Local recording with file upload after completion
  fileUpload,
}
