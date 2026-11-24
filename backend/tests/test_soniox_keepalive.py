#!/usr/bin/env python3
"""
Test script to verify Soniox WebSocket keep-alive functionality.

This test verifies that:
1. Keep-alive messages are sent during silence periods
2. Keep-alive messages follow the correct format {"type": "keepalive"}
3. Keep-alive interval is configurable
4. Keep-alive stops when audio is being sent
5. Keep-alive resumes after silence periods
"""

import asyncio
import json
import os
import time
from unittest.mock import AsyncMock, MagicMock, patch
import pytest
import pytest_asyncio

# Add the backend directory to the path so we can import modules
import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '..'))

from utils.stt.soniox_stream import process_audio_soniox


class MockWebSocket:
    """Mock WebSocket for testing keep-alive functionality."""
    
    instances = []

    def __init__(self):
        self.instances.append(self)
        self.sent_messages = []
        self.closed = False
        self._receive_closed = asyncio.Event()
        self._keepalive_task = None
        self._update_last_audio_time = None
    
    async def send(self, message):
        """Mock send method that records sent messages."""
        self.sent_messages.append(message)
        print(f"Mock WebSocket sent: {message}")
    
    async def close(self):
        """Mock close method."""
        self.closed = True
        self._receive_closed.set()
        print("Mock WebSocket closed")


    def __aiter__(self):
        return self

    async def __anext__(self):
        await self._receive_closed.wait()
        raise StopAsyncIteration


@pytest_asyncio.fixture(autouse=True)
async def close_mock_sockets():
    MockWebSocket.instances.clear()
    yield
    for socket in MockWebSocket.instances:
        await socket.close()
        tasks = [getattr(socket, name, None) for name in ('_on_message_task', '_keepalive_task')]
        await asyncio.gather(*(task for task in tasks if task is not None), return_exceptions=True)


@pytest.mark.asyncio
async def test_soniox_keepalive_basic():
    """Test basic keep-alive functionality."""
    
    # Mock the websockets.connect function
    mock_socket = MockWebSocket()
    
    with patch('utils.stt.soniox_stream.websockets.connect', new=AsyncMock(return_value=mock_socket)):
        with patch.dict(os.environ, {'SONIOX_API_KEY': 'test_key'}):
            # Mock the stream_transcript callback
            stream_transcript = MagicMock()
            
            # Create Soniox connection with short keepalive interval for testing
            socket = await process_audio_soniox(
                stream_transcript=stream_transcript,
                sample_rate=16000,
                language='en',
                uid='test_user',
                keepalive_interval=2  # 2 seconds for faster testing
            )
            
            # Verify socket has keep-alive functionality
            assert hasattr(socket, '_keepalive_task')
            assert hasattr(socket, '_update_last_audio_time')
            assert socket._keepalive_task is not None
            
            # Wait for keep-alive messages to be sent
            await asyncio.sleep(3)  # Wait longer than keepalive_interval
            
            # Check that keep-alive messages were sent
            keepalive_messages = [
                msg for msg in mock_socket.sent_messages 
                if isinstance(msg, str) and 'keepalive' in msg
            ]
            
            assert len(keepalive_messages) > 0, "No keep-alive messages were sent"
            
            # Verify keep-alive message format
            for msg in keepalive_messages:
                parsed = json.loads(msg)
                assert parsed == {"type": "keepalive"}, f"Invalid keep-alive format: {parsed}"
            
            # Clean up
            if socket._keepalive_task:
                socket._keepalive_task.cancel()
                try:
                    await socket._keepalive_task
                except asyncio.CancelledError:
                    pass


@pytest.mark.asyncio
async def test_soniox_keepalive_stops_during_audio():
    """Test that keep-alive stops when audio is being sent."""
    
    mock_socket = MockWebSocket()
    
    with patch('utils.stt.soniox_stream.websockets.connect', new=AsyncMock(return_value=mock_socket)):
        with patch.dict(os.environ, {'SONIOX_API_KEY': 'test_key'}):
            stream_transcript = MagicMock()
            
            socket = await process_audio_soniox(
                stream_transcript=stream_transcript,
                sample_rate=16000,
                language='en',
                uid='test_user',
                keepalive_interval=1  # 1 second for testing
            )
            
            # Wait for initial keep-alive
            await asyncio.sleep(1.5)
            initial_keepalive_count = len([
                msg for msg in mock_socket.sent_messages 
                if isinstance(msg, str) and 'keepalive' in msg
            ])
            
            # Keep transmitting throughout the observation window. A single
            # update followed by 1.5s of silence correctly needs a heartbeat.
            for _ in range(6):
                await socket.send(b'\x00' * 320)
                await asyncio.sleep(0.25)
            new_keepalive_count = len([
                msg for msg in mock_socket.sent_messages 
                if isinstance(msg, str) and 'keepalive' in msg
            ])
            
            # Should not have sent new keep-alive messages since audio was "sent"
            assert new_keepalive_count == initial_keepalive_count, \
                "Keep-alive messages were sent even though audio was being transmitted"
            
            # Clean up
            if socket._keepalive_task:
                socket._keepalive_task.cancel()
                try:
                    await socket._keepalive_task
                except asyncio.CancelledError:
                    pass


@pytest.mark.asyncio
async def test_soniox_keepalive_configurable_interval():
    """Test that keep-alive interval is configurable."""
    
    mock_socket = MockWebSocket()
    
    with patch('utils.stt.soniox_stream.websockets.connect', new=AsyncMock(return_value=mock_socket)):
        with patch.dict(os.environ, {'SONIOX_API_KEY': 'test_key'}):
            stream_transcript = MagicMock()
            
            # Test with custom interval
            custom_interval = 3
            socket = await process_audio_soniox(
                stream_transcript=stream_transcript,
                sample_rate=16000,
                language='en',
                uid='test_user',
                keepalive_interval=custom_interval
            )
            
            # Wait less than the interval
            await asyncio.sleep(custom_interval - 0.5)
            
            # Should not have sent keep-alive yet
            keepalive_messages = [
                msg for msg in mock_socket.sent_messages 
                if isinstance(msg, str) and 'keepalive' in msg
            ]
            assert len(keepalive_messages) == 0, "Keep-alive sent too early"
            
            # Wait for the full interval
            await asyncio.sleep(1)
            
            # Now should have sent keep-alive
            keepalive_messages = [
                msg for msg in mock_socket.sent_messages 
                if isinstance(msg, str) and 'keepalive' in msg
            ]
            assert len(keepalive_messages) > 0, "Keep-alive not sent after interval"
            
            # Clean up
            if socket._keepalive_task:
                socket._keepalive_task.cancel()
                try:
                    await socket._keepalive_task
                except asyncio.CancelledError:
                    pass


@pytest.mark.asyncio
async def test_soniox_latency_optimization():
    """Test that the real-time latency optimization parameter is included."""

    mock_socket = MockWebSocket()

    with patch('utils.stt.soniox_stream.websockets.connect', new=AsyncMock(return_value=mock_socket)):
        with patch.dict(os.environ, {'SONIOX_API_KEY': 'test_key'}):
            stream_transcript = MagicMock()

            socket = await process_audio_soniox(
                stream_transcript=stream_transcript,
                sample_rate=16000,
                language='en',
                uid='test_user'
            )

            # Check that the initial request was sent with the latency optimization parameter
            initial_requests = [
                msg for msg in mock_socket.sent_messages
                if isinstance(msg, str) and 'max_non_final_tokens_duration_ms' in msg
            ]

            assert len(initial_requests) > 0, "Initial request with latency optimization not found"

            # Verify the parameter value
            request_data = json.loads(initial_requests[0])
            assert 'max_non_final_tokens_duration_ms' in request_data, \
                "max_non_final_tokens_duration_ms parameter missing from request"
            assert request_data['max_non_final_tokens_duration_ms'] == 4000, \
                f"Expected 4000ms, got {request_data['max_non_final_tokens_duration_ms']}"

            # Clean up
            if socket._keepalive_task:
                socket._keepalive_task.cancel()
                try:
                    await socket._keepalive_task
                except asyncio.CancelledError:
                    pass


if __name__ == "__main__":
    # Run tests manually if executed directly
    asyncio.run(test_soniox_keepalive_basic())
    print("✅ Basic keep-alive test passed")

    asyncio.run(test_soniox_keepalive_stops_during_audio())
    print("✅ Keep-alive stops during audio test passed")

    asyncio.run(test_soniox_keepalive_configurable_interval())
    print("✅ Configurable interval test passed")

    asyncio.run(test_soniox_latency_optimization())
    print("✅ Latency optimization test passed")

    print("\n🎉 All Soniox keep-alive tests passed!")
