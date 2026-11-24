"""
Unit tests for mood pixel inventory calculation

Tests that mood pixel inventory matches emotion trends data source.
"""
import pytest
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch, MagicMock
from collections import defaultdict

# Mock the database modules before importing routers
import sys

# Create comprehensive mocks
mock_dev_db = MagicMock()
mock_redis = MagicMock()
mock_redis.get_generic_cache = MagicMock(return_value=None)
mock_redis.set_generic_cache = MagicMock()
mock_mood_pixel = MagicMock()
mock_mood_pixel.MOOD_PIXEL_KEYS = ['happy', 'angry', 'sad', 'surprised', 'calm']
mock_endpoints = MagicMock()
mock_conversation = MagicMock()
mock_discover = MagicMock()
mock_discover.VALID_EMOTIONS = {'happy', 'angry', 'sad', 'surprised', 'calm'}

sys.modules['database.developer_data'] = mock_dev_db
sys.modules['database.redis_db'] = mock_redis
sys.modules['models.mood_pixel'] = mock_mood_pixel
sys.modules['models.conversation'] = mock_conversation
sys.modules['utils.other.endpoints'] = mock_endpoints
sys.modules['routers.discover'] = mock_discover

# Now we can import the functions we want to test
from routers.mood_pixel import _inventory_from_conversations, _inventory_fallback
MOOD_PIXEL_KEYS = mock_mood_pixel.MOOD_PIXEL_KEYS


class TestMoodPixelInventory:
    """Test mood pixel inventory calculation logic"""

    def test_inventory_fallback_even_distribution(self):
        """Test that fallback inventory evenly distributes 45 fillable cells"""
        # Assuming a board has 45 fillable cells
        with patch('routers.mood_pixel._CELL_TYPES', {'test_board': ['fillable'] * 45}):
            inventory = _inventory_fallback('test_board')

            # Should distribute 45 / 5 = 9 cells per mood
            assert sum(inventory.values()) == 45
            assert all(count == 9 for count in inventory.values())

    def test_inventory_fallback_uneven_distribution(self):
        """Test fallback inventory with cells not evenly divisible"""
        # 47 cells: 9 per mood + 2 remainder
        with patch('routers.mood_pixel._CELL_TYPES', {'test_board': ['fillable'] * 47}):
            inventory = _inventory_fallback('test_board')

            assert sum(inventory.values()) == 47
            # First 2 moods get extra cell
            counts = list(inventory.values())
            assert counts.count(10) == 2  # 2 moods with 10
            assert counts.count(9) == 3   # 3 moods with 9

    @patch('database.developer_data.get_conversations')
    def test_inventory_from_conversations_basic(self, mock_get_conversations):
        """Test inventory calculation from conversations"""
        # Mock conversations with different emotions
        now = datetime.now(timezone.utc)

        # Mock Conversation objects
        mock_convos = []
        emotions = [('happy', 1), ('happy', 2), ('sad', 3), ('calm', 4), ('angry', 5)]
        for emotion, days_ago in emotions:
            convo = Mock()
            convo.eir_emotion = emotion
            convo.created_at = now - timedelta(days=days_ago)
            mock_convos.append(convo)

        mock_get_conversations.return_value = mock_convos

        inventory = _inventory_from_conversations('dev_id', 'user_id', days=7)

        # Should count: happy=2, sad=1, calm=1, angry=1, surprised=0
        assert inventory['happy'] == 2
        assert inventory['sad'] == 1
        assert inventory['calm'] == 1
        assert inventory['angry'] == 1
        assert inventory['surprised'] == 0

    @patch('database.developer_data.get_conversations')
    def test_inventory_from_conversations_empty(self, mock_get_conversations):
        """Test inventory with no conversations returns minimal fallback"""
        mock_get_conversations.return_value = []

        inventory = _inventory_from_conversations('dev_id', 'user_id', days=7)

        # Should return 1 of each for playability
        assert all(count == 1 for count in inventory.values())
        assert len(inventory) == len(MOOD_PIXEL_KEYS)

    @patch('database.developer_data.get_conversations')
    def test_inventory_filters_by_date_range(self, mock_get_conversations):
        """Test that inventory relies on server-side date filtering"""
        now = datetime.now(timezone.utc)

        # The production code uses start_date parameter, so the DB should
        # already filter conversations. We simulate this by returning only
        # conversations within the date range.
        mock_convos = []
        for days_ago in [1, 5]:  # Only within 7-day window
            convo = Mock()
            convo.eir_emotion = 'happy'
            convo.created_at = now - timedelta(days=days_ago)
            mock_convos.append(convo)

        mock_get_conversations.return_value = mock_convos

        inventory = _inventory_from_conversations('dev_id', 'user_id', days=7)

        # Should count 2 (within 7 days)
        assert inventory['happy'] == 2

        # Verify that start_date parameter was passed
        call_kwargs = mock_get_conversations.call_args[1]
        assert 'start_date' in call_kwargs

    @patch('database.developer_data.get_conversations')
    def test_inventory_ignores_invalid_emotions(self, mock_get_conversations):
        """Test that invalid emotion values are ignored"""
        now = datetime.now(timezone.utc)

        mock_convos = []
        for emotion in ['happy', 'invalid_emotion', None, '']:
            convo = Mock()
            convo.eir_emotion = emotion
            convo.created_at = now - timedelta(days=1)
            mock_convos.append(convo)

        mock_get_conversations.return_value = mock_convos

        inventory = _inventory_from_conversations('dev_id', 'user_id', days=7)

        # Should only count the valid 'happy' emotion
        assert inventory['happy'] == 1
        assert sum(inventory.values()) == 1


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
