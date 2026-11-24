#!/bin/bash
#
# End-to-end test for audio upload API
#
# Usage:
#   ./test_audio_upload_e2e.sh <API_BASE_URL> <AUTH_TOKEN>
#
# Example:
#   ./test_audio_upload_e2e.sh https://api.example.com "Bearer eyJ..."
#

set -e

API_BASE=${1:-"http://localhost:8000"}
AUTH_TOKEN=${2:-""}

echo "========================================"
echo "Audio Upload API E2E Test"
echo "========================================"
echo "API Base: $API_BASE"
echo ""

# Create test directory
TEST_DIR=$(mktemp -d)
echo "Test directory: $TEST_DIR"

# Generate a simple test WAV file (5 seconds of silence with some noise)
echo "Generating test audio file..."
TEST_WAV="$TEST_DIR/test_audio.wav"

# Use ffmpeg to generate a test audio file with speech-like noise
if command -v ffmpeg &> /dev/null; then
    # Generate 6 seconds of sine wave (simulates a simple tone)
    ffmpeg -f lavfi -i "sine=frequency=440:duration=6" \
           -ar 16000 -ac 1 \
           "$TEST_WAV" \
           -y -loglevel error
    echo "✓ Created test WAV file using ffmpeg"
else
    # Fallback: create a minimal WAV file with Python
    python3 << 'EOF'
import wave
import struct
import math
import sys

filename = sys.argv[1] if len(sys.argv) > 1 else '/tmp/test.wav'
duration = 6  # seconds
sample_rate = 16000
frequency = 440

with wave.open(filename, 'wb') as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(sample_rate)

    for i in range(duration * sample_rate):
        t = i / sample_rate
        sample = int(16000 * math.sin(2 * math.pi * frequency * t))
        wav.writeframes(struct.pack('<h', sample))

print(f"Created {filename}")
EOF
    python3 -c "
import wave, struct, math
with wave.open('$TEST_WAV', 'wb') as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(16000)
    for i in range(6 * 16000):
        sample = int(16000 * math.sin(2 * 3.14159 * 440 * i / 16000))
        wav.writeframes(struct.pack('<h', sample))
"
    echo "✓ Created test WAV file using Python"
fi

# Check file size
FILE_SIZE=$(stat -f%z "$TEST_WAV" 2>/dev/null || stat -c%s "$TEST_WAV")
echo "  File size: $FILE_SIZE bytes"

# Test 1: Health check
echo ""
echo "--- Test 1: Health Check ---"
HEALTH_RESPONSE=$(curl -s -w "\n%{http_code}" "$API_BASE/health_check")
HEALTH_STATUS=$(echo "$HEALTH_RESPONSE" | tail -n1)
HEALTH_BODY=$(echo "$HEALTH_RESPONSE" | head -n-1)

if [ "$HEALTH_STATUS" = "200" ]; then
    echo "✓ Health check passed: $HEALTH_BODY"
else
    echo "✗ Health check failed: HTTP $HEALTH_STATUS"
    echo "  Response: $HEALTH_BODY"
fi

# Test 2: Upload without auth (should fail with 401/403)
echo ""
echo "--- Test 2: Upload without auth ---"
NOAUTH_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "$API_BASE/v1/conversations/upload-audio" \
    -F "file=@$TEST_WAV" \
    -F "language=en")
NOAUTH_STATUS=$(echo "$NOAUTH_RESPONSE" | tail -n1)

if [ "$NOAUTH_STATUS" = "401" ] || [ "$NOAUTH_STATUS" = "403" ] || [ "$NOAUTH_STATUS" = "422" ]; then
    echo "✓ Correctly rejected unauthorized request: HTTP $NOAUTH_STATUS"
else
    echo "⚠ Unexpected response: HTTP $NOAUTH_STATUS"
fi

# Test 3: Upload with auth (if token provided)
if [ -n "$AUTH_TOKEN" ]; then
    echo ""
    echo "--- Test 3: Upload with auth ---"

    UPLOAD_RESPONSE=$(curl -s -w "\n%{http_code}" \
        -X POST "$API_BASE/v1/conversations/upload-audio" \
        -H "Authorization: $AUTH_TOKEN" \
        -F "file=@$TEST_WAV" \
        -F "language=multi" \
        -F "auto_process=false")

    UPLOAD_STATUS=$(echo "$UPLOAD_RESPONSE" | tail -n1)
    UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE" | head -n-1)

    if [ "$UPLOAD_STATUS" = "200" ]; then
        echo "✓ Upload successful!"
        echo "  Response:"
        echo "$UPLOAD_BODY" | python3 -m json.tool 2>/dev/null || echo "$UPLOAD_BODY"

        # Extract conversation ID
        CONV_ID=$(echo "$UPLOAD_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conversation_id',''))" 2>/dev/null)
        if [ -n "$CONV_ID" ]; then
            echo ""
            echo "  Conversation ID: $CONV_ID"
        fi

        # Check transcript segments
        SEG_COUNT=$(echo "$UPLOAD_BODY" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('transcript_segments',[])))" 2>/dev/null)
        echo "  Transcript segments: $SEG_COUNT"

    else
        echo "✗ Upload failed: HTTP $UPLOAD_STATUS"
        echo "  Response: $UPLOAD_BODY"
    fi
else
    echo ""
    echo "--- Test 3: Upload with auth ---"
    echo "⚠ Skipped: No AUTH_TOKEN provided"
    echo "  Run with: ./test_audio_upload_e2e.sh <API_URL> 'Bearer <token>'"
fi

# Cleanup
echo ""
echo "--- Cleanup ---"
rm -rf "$TEST_DIR"
echo "✓ Cleaned up test files"

echo ""
echo "========================================"
echo "Test Complete"
echo "========================================"
