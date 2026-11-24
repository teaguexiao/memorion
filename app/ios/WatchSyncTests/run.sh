#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$TEST_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/memorion-watch-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
for module in WatchConnectivity Flutter; do
  xcrun swiftc -swift-version 5 -emit-library -emit-module -module-name "$module" \
    "$TEST_DIR/Stubs/$module.swift" -o "$BUILD_DIR/lib$module.dylib" \
    -emit-module-path "$BUILD_DIR/$module.swiftmodule"
done
xcrun swiftc -swift-version 5 -I "$BUILD_DIR" -L "$BUILD_DIR" -lWatchConnectivity -lFlutter \
  -Xlinker -rpath -Xlinker "$BUILD_DIR" \
  "$IOS_DIR/MemorionWatch/WatchReceiptProtocol.swift" \
  "$IOS_DIR/MemorionWatch/WatchRecordingMetadata.swift" \
  "$IOS_DIR/MemorionWatch/WatchMomentStore.swift" \
  "$IOS_DIR/MemorionWatch/PendingRecordingStore.swift" \
  "$IOS_DIR/MemorionWatch/WatchTransfer.swift" \
  "$IOS_DIR/Runner/WatchAudioPreparation.swift" \
  "$IOS_DIR/Runner/WatchSessionService.swift" \
  "$TEST_DIR/main.swift" -o "$BUILD_DIR/WatchSyncTests"
"$BUILD_DIR/WatchSyncTests"
xcrun swiftc -swift-version 5 "$IOS_DIR/MemorionWatch/WatchRecordingControlState.swift" \
  "$TEST_DIR/control_state.swift" -o "$BUILD_DIR/WatchControlTests"
"$BUILD_DIR/WatchControlTests"
