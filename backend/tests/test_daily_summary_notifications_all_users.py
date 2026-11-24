#!/usr/bin/env python3
"""
Test script to send daily summary notifications to all users.
This bypasses timezone restrictions and sends notifications immediately for testing.
"""

import asyncio
import sys
import os
from unittest.mock import patch
from datetime import datetime, time

# Add the backend directory to the Python path
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Load environment variables from .env file
from dotenv import load_dotenv
load_dotenv()

# Initialize Firebase
import firebase_admin
from firebase_admin import credentials
import json

if not firebase_admin._apps:
    # Initialize Firebase with service account
    service_account_json = os.getenv('SERVICE_ACCOUNT_JSON')
    if service_account_json:
        service_account_info = json.loads(service_account_json)
        cred = credentials.Certificate(service_account_info)
        firebase_admin.initialize_app(cred)
        print("✅ Firebase initialized successfully")
    else:
        print("❌ SERVICE_ACCOUNT_JSON not found in environment variables")

# Import the notification functions
from utils.other.notifications import send_daily_summary_notification
from modal.job_modal_standalone import send_daily_summary_notification as modal_send_daily_summary_notification
import database.notifications as notification_db


async def test_send_notifications_to_all_users_original():
    """Test sending daily summary notifications to all users using the original implementation"""
    print("🧪 Testing original implementation (utils/other/notifications.py)")
    print("=" * 60)
    
    try:
        # Get all users with FCM tokens (bypass timezone filtering)
        with patch('utils.other.notifications._get_timezones_at_time') as mock_tz:
            # Mock to return a timezone that will match some users
            mock_tz.return_value = ['UTC', 'America/New_York', 'Europe/London', 'Asia/Tokyo']
            
            print("📤 Sending daily summary notifications to all users...")
            result = await send_daily_summary_notification()
            
            if result:
                print(f"✅ Original implementation: Notifications sent successfully!")
                print(f"📊 Users processed: {len(result) if isinstance(result, list) else 'Unknown'}")
                return True
            else:
                print("❌ Original implementation: No notifications sent")
                return False
                
    except Exception as e:
        print(f"❌ Original implementation failed: {e}")
        import traceback
        traceback.print_exc()
        return False


async def test_send_notifications_to_all_users_modal():
    """Test sending daily summary notifications to all users using the modal implementation"""
    print("\n🧪 Testing modal implementation (modal/job_modal_standalone.py)")
    print("=" * 60)
    
    try:
        # Import the modal functions
        from modal.job_modal_standalone import get_timezones_at_time, get_users_id_in_timezones
        
        # Get all users with FCM tokens (bypass timezone filtering)
        with patch('modal.job_modal_standalone.get_timezones_at_time') as mock_tz:
            # Mock to return a timezone that will match some users
            mock_tz.return_value = ['UTC', 'America/New_York', 'Europe/London', 'Asia/Tokyo']
            
            print("📤 Sending daily summary notifications to all users...")
            result = await modal_send_daily_summary_notification()
            
            if result:
                print(f"✅ Modal implementation: Notifications sent successfully!")
                print(f"📊 Users processed: {len(result) if isinstance(result, list) else 'Unknown'}")
                return True
            else:
                print("❌ Modal implementation: No notifications sent")
                return False
                
    except Exception as e:
        print(f"❌ Modal implementation failed: {e}")
        import traceback
        traceback.print_exc()
        return False


async def test_get_all_users_with_tokens():
    """Test getting all users with FCM tokens"""
    print("\n🔍 Getting all users with FCM tokens...")
    print("=" * 60)
    
    try:
        # Get all users with tokens by using a broad timezone list
        all_timezones = [
            'UTC', 'America/New_York', 'America/Los_Angeles', 'America/Chicago',
            'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Asia/Tokyo',
            'Asia/Shanghai', 'Asia/Kolkata', 'Australia/Sydney', 'America/Toronto'
        ]
        
        users_with_tokens = await notification_db.get_users_token_in_timezones(all_timezones)
        users_with_ids = await notification_db.get_users_id_in_timezones(all_timezones)
        
        print(f"📊 Found {len(users_with_tokens)} users with FCM tokens")
        print(f"📊 Found {len(users_with_ids)} users with IDs and tokens")
        
        if users_with_tokens:
            print(f"🔑 Sample token: {users_with_tokens[0][:20]}...")
        
        if users_with_ids:
            print(f"👤 Sample user: ID={users_with_ids[0][0]}, Token={users_with_ids[0][1][:20]}...")
        
        return len(users_with_tokens) > 0
        
    except Exception as e:
        print(f"❌ Failed to get users: {e}")
        import traceback
        traceback.print_exc()
        return False


async def send_test_notification_to_specific_user(user_id: str = None):
    """Send a test notification to a specific user"""
    print(f"\n🎯 Sending test notification to specific user: {user_id or 'first available user'}")
    print("=" * 60)
    
    try:
        if not user_id:
            # Get the first available user
            all_timezones = ['UTC', 'America/New_York', 'Europe/London', 'Asia/Tokyo']
            users_with_ids = await notification_db.get_users_id_in_timezones(all_timezones)
            
            if not users_with_ids:
                print("❌ No users found with FCM tokens")
                return False
            
            user_id = users_with_ids[0][0]
            user_token = users_with_ids[0][1]
        else:
            user_token = notification_db.get_token_only(user_id)
            if not user_token:
                print(f"❌ No FCM token found for user {user_id}")
                return False
        
        print(f"👤 Target user: {user_id}")
        print(f"🔑 Token: {user_token[:20]}...")
        
        # Mock the timezone and user functions to target this specific user
        with patch('utils.other.notifications._get_timezones_at_time') as mock_tz:
            with patch('database.notifications.get_users_id_in_timezones') as mock_users:
                mock_tz.return_value = ['UTC']
                mock_users.return_value = [(user_id, user_token)]
                
                print("📤 Sending daily summary notification...")
                result = await send_daily_summary_notification()
                
                if result:
                    print("✅ Test notification sent successfully!")
                    return True
                else:
                    print("❌ Test notification failed")
                    return False
                    
    except Exception as e:
        print(f"❌ Failed to send test notification: {e}")
        import traceback
        traceback.print_exc()
        return False


async def main():
    """Main test function"""
    print("🚀 Daily Summary Notification Test Suite")
    print("=" * 60)
    print("This script tests the daily summary notification system")
    print("and can send notifications to all users for testing purposes.")
    print()
    
    # Test 1: Get all users with tokens
    users_available = await test_get_all_users_with_tokens()
    
    if not users_available:
        print("\n❌ No users with FCM tokens found. Cannot proceed with tests.")
        return
    
    # Test 2: Send notifications using original implementation
    original_success = await test_send_notifications_to_all_users_original()
    
    # Test 3: Send notifications using modal implementation
    modal_success = await test_send_notifications_to_all_users_modal()
    
    # Test 4: Send test notification to specific user
    specific_success = await send_test_notification_to_specific_user()
    
    # Summary
    print("\n📋 Test Results Summary")
    print("=" * 60)
    print(f"✅ Users found: {users_available}")
    print(f"✅ Original implementation: {original_success}")
    print(f"✅ Modal implementation: {modal_success}")
    print(f"✅ Specific user test: {specific_success}")
    
    if original_success and modal_success:
        print("\n🎉 All tests passed! Daily summary notifications are working correctly.")
        print("💡 Users should now be able to tap notifications to navigate to daily summaries.")
    else:
        print("\n⚠️  Some tests failed. Check the logs above for details.")


if __name__ == "__main__":
    asyncio.run(main())
