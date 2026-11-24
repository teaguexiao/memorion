#!/usr/bin/env python3
"""
Integration test for Soniox WebSocket keep-alive functionality.

This test demonstrates the keep-alive functionality in a realistic scenario
where audio is sent intermittently with silence periods in between.
"""

import asyncio
import json
import os
import time
from unittest.mock import AsyncMock, MagicMock, patch

# Add the backend directory to the path
import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '..'))

from utils.stt.soniox_stream import process_audio_soniox


class MockWebSocketWithMessages:
    """Mock WebSocket that simulates Soniox responses."""
    
    def __init__(self):
        self.sent_messages = []
        self.closed = False
        self._keepalive_task = None
        self._update_last_audio_time = None
        self.message_handler = None
    
    async def send(self, message):
        """Mock send method that records sent messages."""
        self.sent_messages.append(message)
        
        # If it's a keepalive message, log it
        if isinstance(message, str) and 'keepalive' in message:
            print(f"📡 Sent keep-alive message: {message}")
        elif isinstance(message, (bytes, bytearray)):
            print(f"🎵 Sent audio data: {len(message)} bytes")
        else:
            print(f"📤 Sent message: {message}")
    
    async def close(self):
        """Mock close method."""
        self.closed = True
        print("🔌 WebSocket connection closed")
    
    def __aiter__(self):
        """Make the socket async iterable for message handling."""
        return self
    
    async def __anext__(self):
        """Simulate receiving messages from Soniox."""
        # Simulate periodic responses from Soniox
        await asyncio.sleep(5)
        
        # Return a mock Soniox response
        response = {
            "tokens": [
                {
                    "text": "hello",
                    "start_ms": 1000,
                    "end_ms": 1500,
                    "is_final": True
                }
            ]
        }
        return json.dumps(response)


async def simulate_audio_with_silence():
    """
    Simulate a realistic audio streaming scenario with periods of silence.
    
    This demonstrates how the keep-alive functionality maintains the connection
    during VAD-detected silence periods.
    """
    print("🚀 Starting Soniox keep-alive integration test...")
    
    mock_socket = MockWebSocketWithMessages()
    
    with patch('utils.stt.soniox_stream.websockets.connect', new=AsyncMock(return_value=mock_socket)):
        with patch.dict(os.environ, {'SONIOX_API_KEY': 'test_key'}):
            
            # Mock transcript handler
            def stream_transcript(segments):
                print(f"📝 Received transcript segments: {len(segments)}")
            
            # Create Soniox connection with realistic keep-alive interval
            print("🔗 Connecting to Soniox WebSocket...")
            socket = await process_audio_soniox(
                stream_transcript=stream_transcript,
                sample_rate=16000,
                language='en',
                uid='test_user',
                keepalive_interval=10  # 10 seconds (realistic interval)
            )
            
            print("✅ Connected successfully with keep-alive enabled")
            
            # Simulate audio streaming pattern:
            # 1. Send audio for 5 seconds
            # 2. Silence for 15 seconds (should trigger keep-alive)
            # 3. Send audio for 3 seconds
            # 4. Silence for 20 seconds (should trigger multiple keep-alives)
            
            print("\n📊 Simulation timeline:")
            print("0-5s: Sending audio")
            print("5-20s: Silence (expect keep-alive at ~15s)")
            print("20-23s: Sending audio")
            print("23-43s: Silence (expect keep-alives at ~33s and ~43s)")
            
            start_time = time.time()
            
            # Phase 1: Send audio for 5 seconds
            print("\n🎵 Phase 1: Sending audio...")
            for i in range(5):
                # Simulate sending audio data
                audio_data = b'\x00' * 320  # Mock audio chunk
                await socket.send(audio_data)
                socket._update_last_audio_time()  # Update last audio time
                await asyncio.sleep(1)
            
            print("🔇 Phase 2: Silence period (15 seconds)...")
            # Phase 2: Silence for 15 seconds
            await asyncio.sleep(15)
            
            # Phase 3: Send audio for 3 seconds
            print("🎵 Phase 3: Sending audio again...")
            for i in range(3):
                audio_data = b'\x00' * 320
                await socket.send(audio_data)
                socket._update_last_audio_time()
                await asyncio.sleep(1)
            
            print("🔇 Phase 4: Long silence period (20 seconds)...")
            # Phase 4: Silence for 20 seconds
            await asyncio.sleep(20)
            
            # Analyze results
            print("\n📈 Results Analysis:")
            
            # Count different types of messages
            audio_messages = [msg for msg in mock_socket.sent_messages if isinstance(msg, bytes)]
            keepalive_messages = [
                msg for msg in mock_socket.sent_messages 
                if isinstance(msg, str) and 'keepalive' in msg
            ]
            other_messages = [
                msg for msg in mock_socket.sent_messages 
                if not isinstance(msg, bytes) and not (isinstance(msg, str) and 'keepalive' in msg)
            ]
            
            print(f"🎵 Audio messages sent: {len(audio_messages)}")
            print(f"📡 Keep-alive messages sent: {len(keepalive_messages)}")
            print(f"📤 Other messages sent: {len(other_messages)}")
            
            # Verify keep-alive messages
            print(f"\n📡 Keep-alive message details:")
            for i, msg in enumerate(keepalive_messages):
                try:
                    parsed = json.loads(msg)
                    print(f"  {i+1}. {parsed}")
                    assert parsed == {"type": "keepalive"}, f"Invalid keep-alive format: {parsed}"
                except json.JSONDecodeError:
                    print(f"  {i+1}. Invalid JSON: {msg}")
            
            # Verify we got the expected number of keep-alive messages
            # Should have at least 2-3 keep-alive messages during the silence periods
            assert len(keepalive_messages) >= 2, f"Expected at least 2 keep-alive messages, got {len(keepalive_messages)}"
            
            print(f"\n✅ Test completed successfully!")
            print(f"⏱️  Total duration: {time.time() - start_time:.1f} seconds")
            print(f"📊 Keep-alive functionality is working correctly")
            
            # Clean up
            if socket._keepalive_task:
                socket._keepalive_task.cancel()
                try:
                    await socket._keepalive_task
                except asyncio.CancelledError:
                    pass
            
            await socket.close()


async def simulate_vad_integration():
    """
    Test how keep-alive integrates with VAD (Voice Activity Detection).
    
    This simulates the real-world scenario where VAD detects silence
    and the keep-alive maintains the connection during those periods.
    """
    print("\n🎯 Testing VAD integration with keep-alive...")
    
    mock_socket = MockWebSocketWithMessages()
    
    with patch('utils.stt.soniox_stream.websockets.connect', new=AsyncMock(return_value=mock_socket)):
        with patch.dict(os.environ, {'SONIOX_API_KEY': 'test_key'}):
            
            def stream_transcript(segments):
                print(f"📝 VAD detected speech: {len(segments)} segments")
            
            socket = await process_audio_soniox(
                stream_transcript=stream_transcript,
                sample_rate=16000,
                language='en',
                uid='test_user',
                keepalive_interval=8  # 8 seconds
            )
            
            print("🔗 Connected with VAD-aware keep-alive")
            
            # Simulate VAD behavior:
            # - VAD detects speech: send audio + update time
            # - VAD detects silence: don't send audio, let keep-alive handle it
            
            print("🗣️  VAD detects speech...")
            for i in range(3):
                await socket.send(b'\x00' * 320)
                socket._update_last_audio_time()
                await asyncio.sleep(1)
            
            print("🤫 VAD detects silence (keep-alive should maintain connection)...")
            await asyncio.sleep(12)  # Longer than keep-alive interval
            
            print("🗣️  VAD detects speech again...")
            for i in range(2):
                await socket.send(b'\x00' * 320)
                socket._update_last_audio_time()
                await asyncio.sleep(1)
            
            # Verify keep-alive worked during silence
            keepalive_count = len([
                msg for msg in mock_socket.sent_messages 
                if isinstance(msg, str) and 'keepalive' in msg
            ])
            
            print(f"📡 Keep-alive messages during VAD silence: {keepalive_count}")
            assert keepalive_count > 0, "No keep-alive messages sent during VAD silence"
            
            print("✅ VAD integration test passed!")
            
            # Clean up
            if socket._keepalive_task:
                socket._keepalive_task.cancel()
                try:
                    await socket._keepalive_task
                except asyncio.CancelledError:
                    pass


if __name__ == "__main__":
    # Run the integration tests
    asyncio.run(simulate_audio_with_silence())
    asyncio.run(simulate_vad_integration())
    
    print("\n🎉 All integration tests passed!")
    print("🔧 Soniox WebSocket keep-alive functionality is working correctly!")
