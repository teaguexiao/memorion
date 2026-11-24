import asyncio
import math
from datetime import datetime

from firebase_admin import messaging

import database.developer_data as dev_db


def send_notification(token: str, title: str, body: str, data: dict = None):
    """Enhanced notification sending with improved error handling and logging"""
    print(f'📱 send_notification to token: {token[:20]}...')

    # Truncate body for notification display (proven pattern from test scripts)
    notification_body = body[:100] + "..." if len(body) > 100 else body

    # Create basic notification
    notification = messaging.Notification(title=title, body=notification_body)

    # Create message with standard configuration
    message = messaging.Message(
        notification=notification,
        token=token
    )

    if data:
        message.data = data

    try:
        response = messaging.send(message)
        print(f'✅ Enhanced notification sent successfully!')
        print(f'📨 FCM Response: {response}')
        print(f'🎯 Notification details:')
        print(f'   - Title: {title}')
        print(f'   - Body: {notification_body}')
        return True
    except Exception as e:
        error_message = str(e)
        if "Requested entity was not found" in error_message:
            print(f'❌ FCM Token not found or invalid: {token[:20]}...')
            print("💡 User may need to reinstall the app or re-login")
            dev_db.remove_fcm_token_by_value(token)
        elif "not a valid FCM registration token" in error_message:
            print(f'❌ Invalid FCM token format: {token[:20]}...')
            dev_db.remove_fcm_token_by_value(token)
        else:
            print(f'❌ Enhanced notification failed: {e}')

        print("🔍 Troubleshooting tips:")
        print("   1. Check if user has notifications enabled")
        print("   2. Verify FCM token is still valid")
        print("   3. Ensure app is installed and logged in")
        return False


async def send_bulk_notification(user_tokens: list, title: str, body: str):
    """Enhanced bulk notification sending with improved error handling and logging"""
    try:
        print(f"📤 Sending enhanced bulk notifications to {len(user_tokens)} users")

        batch_size = 500
        num_batches = math.ceil(len(user_tokens) / batch_size)

        # Truncate body for notification display (proven pattern from test scripts)
        notification_body = body[:100] + "..." if len(body) > 100 else body

        def send_batch(batch_users):
            """Send a batch of notifications with standard configuration"""
            messages = [
                messaging.Message(
                    notification=messaging.Notification(title=title, body=notification_body),
                    token=token
                )
                for token in batch_users
            ]

            try:
                response = messaging.send_each(messages)

                # Enhanced logging for delivery verification
                success_count = response.success_count
                failure_count = response.failure_count

                print(f"📊 Batch delivery results:")
                print(f"   ✅ Successful: {success_count}")
                print(f"   ❌ Failed: {failure_count}")

                # Log failed tokens for cleanup
                if failure_count > 0:
                    for i, result in enumerate(response.responses):
                        if not result.success:
                            failed_token = batch_users[i]
                            error_msg = result.exception
                            print(f"   🔍 Failed token {failed_token[:20]}...: {error_msg}")

                            # Remove invalid tokens
                            if "Requested entity was not found" in str(error_msg) or "not a valid FCM registration token" in str(error_msg):
                                dev_db.remove_fcm_token_by_value(failed_token)
                                print(f"   🗑️ Removed invalid token: {failed_token[:20]}...")

                return response

            except Exception as e:
                print(f"❌ Batch send failed: {e}")
                return None

        tasks = []
        for i in range(num_batches):
            start = i * batch_size
            end = start + batch_size
            batch_users = user_tokens[start:end]
            print(f"📦 Processing batch {i+1}/{num_batches} ({len(batch_users)} users)")
            task = asyncio.to_thread(send_batch, batch_users)
            tasks.append(task)

        results = await asyncio.gather(*tasks)

        # Calculate overall statistics
        total_success = sum(r.success_count for r in results if r)
        total_failure = sum(r.failure_count for r in results if r)

        print(f"🎯 Enhanced bulk notification summary:")
        print(f"   📊 Total users targeted: {len(user_tokens)}")
        print(f"   ✅ Successfully delivered: {total_success}")
        print(f"   ❌ Failed deliveries: {total_failure}")
        print(f"   📈 Success rate: {(total_success / len(user_tokens) * 100):.1f}%")

        return results

    except Exception as e:
        print(f"❌ Error in enhanced bulk notification: {e}")
        import traceback
        traceback.print_exc()
