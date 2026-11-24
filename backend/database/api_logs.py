"""
Firestore operations for API logs.

This module provides functions to read and write API log entries
and usage summaries to Firestore.
"""

from datetime import datetime
from typing import Any, Dict, List, Optional

from google.cloud import firestore

from database._client import db
from models.api_log import (
    APILogEntry,
    DailyUsageSummary,
    MonthlyUsageSummary,
    EndpointGroup,
    ResourceType,
)


# ******************************************************
# ***************** LOG WRITES *************************
# ******************************************************


def batch_write_logs(
    developer_id: str, date: str, entries: List[APILogEntry]
) -> None:
    """
    Write multiple log entries in a single batch operation.

    Firestore batches can contain up to 500 operations.

    Args:
        developer_id: The developer ID
        date: The date string (YYYY-MM-DD)
        entries: List of APILogEntry objects to write
    """
    if not entries:
        return

    # Firestore batch limit is 500 operations
    BATCH_LIMIT = 500

    # Split into chunks if needed
    for i in range(0, len(entries), BATCH_LIMIT):
        chunk = entries[i : i + BATCH_LIMIT]
        batch = db.batch()

        logs_collection = (
            db.collection("developer_data")
            .document(developer_id)
            .collection("api_logs_daily")
            .document(date)
            .collection("logs")
        )

        for entry in chunk:
            doc_ref = logs_collection.document(entry.request_id)
            batch.set(doc_ref, entry.model_dump())

        batch.commit()

    # Update daily summary atomically
    update_daily_summary(developer_id, date, entries)


def write_single_log(developer_id: str, entry: APILogEntry) -> None:
    """
    Write a single log entry.

    For most cases, use batch_write_logs for efficiency.

    Args:
        developer_id: The developer ID
        entry: The APILogEntry to write
    """
    date = entry.timestamp.strftime("%Y-%m-%d")

    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_logs_daily")
        .document(date)
        .collection("logs")
        .document(entry.request_id)
    )

    doc_ref.set(entry.model_dump())

    # Update daily summary
    update_daily_summary(developer_id, date, [entry])


# ******************************************************
# ***************** LOG READS **************************
# ******************************************************


def get_logs(
    developer_id: str,
    start_date: str,
    end_date: Optional[str] = None,
    external_user_id: Optional[str] = None,
    endpoint_group: Optional[str] = None,
    resource_type: Optional[str] = None,
    status_code: Optional[int] = None,
    min_response_time_ms: Optional[int] = None,
    limit: int = 100,
    offset: int = 0,
) -> tuple[List[APILogEntry], int]:
    """
    Query log entries with filters.

    Args:
        developer_id: The developer ID
        start_date: Start date (YYYY-MM-DD)
        end_date: End date (YYYY-MM-DD), defaults to start_date
        external_user_id: Filter by external user ID
        endpoint_group: Filter by endpoint group
        resource_type: Filter by resource type
        status_code: Filter by HTTP status code
        min_response_time_ms: Filter by minimum response time
        limit: Maximum results to return
        offset: Offset for pagination

    Returns:
        Tuple of (list of APILogEntry, total count)
    """
    if end_date is None:
        end_date = start_date

    # Generate list of dates to query
    dates = _get_date_range(start_date, end_date)

    all_logs: List[APILogEntry] = []

    for date in dates:
        logs_ref = (
            db.collection("developer_data")
            .document(developer_id)
            .collection("api_logs_daily")
            .document(date)
            .collection("logs")
        )

        # Build query with filters
        query = logs_ref.order_by("timestamp", direction=firestore.Query.DESCENDING)

        if external_user_id:
            query = query.where("external_user_id", "==", external_user_id)

        if endpoint_group:
            query = query.where("endpoint_group", "==", endpoint_group)

        if resource_type:
            query = query.where("resource_type", "==", resource_type)

        if status_code:
            query = query.where("status_code", "==", status_code)

        # Execute query
        docs = query.stream()

        for doc in docs:
            data = doc.to_dict()

            # Apply filters that can't be done in Firestore query
            if min_response_time_ms and data.get("response_time_ms", 0) < min_response_time_ms:
                continue

            all_logs.append(APILogEntry(**data))

    # Sort all logs by timestamp descending
    all_logs.sort(key=lambda x: x.timestamp, reverse=True)

    total_count = len(all_logs)

    # Apply pagination
    paginated = all_logs[offset : offset + limit]

    return paginated, total_count


def get_log_by_id(
    developer_id: str, date: str, request_id: str
) -> Optional[APILogEntry]:
    """
    Get a specific log entry by ID.

    Args:
        developer_id: The developer ID
        date: The date string (YYYY-MM-DD)
        request_id: The request ID

    Returns:
        APILogEntry if found, None otherwise
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_logs_daily")
        .document(date)
        .collection("logs")
        .document(request_id)
    )

    doc = doc_ref.get()
    if not doc.exists:
        return None

    return APILogEntry(**doc.to_dict())


# ******************************************************
# ************** USAGE SUMMARIES ***********************
# ******************************************************


def update_daily_summary(
    developer_id: str, date: str, entries: List[APILogEntry]
) -> None:
    """
    Update daily usage summary with new log entries.

    Uses Firestore atomic increment operations.

    Args:
        developer_id: The developer ID
        date: The date string (YYYY-MM-DD)
        entries: List of new log entries to add to summary
    """
    if not entries:
        return

    summary_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("usage_summaries")
        .document(f"daily_{date}")
    )

    # Calculate increments from entries
    total_requests = len(entries)
    total_errors = sum(1 for e in entries if e.status_code >= 400)
    total_cost = sum(e.cost_estimate for e in entries)

    by_endpoint_group: Dict[str, int] = {}
    by_resource_type: Dict[str, float] = {}
    by_status_code: Dict[str, int] = {}
    by_external_user: Dict[str, int] = {}

    for entry in entries:
        # Count by endpoint group
        group = entry.endpoint_group
        by_endpoint_group[group] = by_endpoint_group.get(group, 0) + 1

        # Sum by resource type
        rt = entry.resource_type
        by_resource_type[rt] = by_resource_type.get(rt, 0.0) + entry.billable_units

        # Count by status code
        sc = str(entry.status_code)
        by_status_code[sc] = by_status_code.get(sc, 0) + 1

        # Count by external user
        if entry.external_user_id:
            by_external_user[entry.external_user_id] = (
                by_external_user.get(entry.external_user_id, 0) + 1
            )

    # Build update data with increments
    update_data: Dict[str, Any] = {
        "date": date,
        "developer_id": developer_id,
        "total_requests": firestore.Increment(total_requests),
        "total_errors": firestore.Increment(total_errors),
        "total_cost": firestore.Increment(total_cost),
        "updated_at": datetime.utcnow(),
    }

    # Add increments for nested maps
    for group, count in by_endpoint_group.items():
        update_data[f"by_endpoint_group.{group}"] = firestore.Increment(count)

    for rt, units in by_resource_type.items():
        update_data[f"by_resource_type.{rt}"] = firestore.Increment(units)

    for sc, count in by_status_code.items():
        update_data[f"by_status_code.{sc}"] = firestore.Increment(count)

    for user_id, count in by_external_user.items():
        # Sanitize user_id for use as field name
        safe_user_id = user_id.replace(".", "_").replace("/", "_")
        update_data[f"by_external_user.{safe_user_id}"] = firestore.Increment(count)

    # Use set with merge to create or update
    summary_ref.set(update_data, merge=True)


def get_daily_summary(developer_id: str, date: str) -> Optional[DailyUsageSummary]:
    """
    Get daily usage summary for a specific date.

    Args:
        developer_id: The developer ID
        date: The date string (YYYY-MM-DD)

    Returns:
        DailyUsageSummary if found, None otherwise
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("usage_summaries")
        .document(f"daily_{date}")
    )

    doc = doc_ref.get()
    if not doc.exists:
        return None

    data = doc.to_dict()
    return DailyUsageSummary(**data)


def get_daily_summaries_range(
    developer_id: str, start_date: str, end_date: str
) -> List[DailyUsageSummary]:
    """
    Get daily usage summaries for a date range.

    Args:
        developer_id: The developer ID
        start_date: Start date (YYYY-MM-DD)
        end_date: End date (YYYY-MM-DD)

    Returns:
        List of DailyUsageSummary objects
    """
    dates = _get_date_range(start_date, end_date)
    summaries: List[DailyUsageSummary] = []

    for date in dates:
        summary = get_daily_summary(developer_id, date)
        if summary:
            summaries.append(summary)

    return summaries


def get_monthly_summary(developer_id: str, month: str) -> Optional[MonthlyUsageSummary]:
    """
    Get monthly usage summary.

    Args:
        developer_id: The developer ID
        month: The month string (YYYY-MM)

    Returns:
        MonthlyUsageSummary if found, None otherwise
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("usage_summaries")
        .document(f"monthly_{month}")
    )

    doc = doc_ref.get()
    if not doc.exists:
        return None

    data = doc.to_dict()
    return MonthlyUsageSummary(**data)


def compute_monthly_summary(developer_id: str, month: str) -> MonthlyUsageSummary:
    """
    Compute and save monthly summary from daily summaries.

    Args:
        developer_id: The developer ID
        month: The month string (YYYY-MM)

    Returns:
        The computed MonthlyUsageSummary
    """
    from datetime import datetime
    import calendar

    # Parse month
    year, month_num = map(int, month.split("-"))

    # Get first and last day of month
    first_day = f"{month}-01"
    last_day = calendar.monthrange(year, month_num)[1]
    last_date = f"{month}-{last_day:02d}"

    # Get all daily summaries for the month
    daily_summaries = get_daily_summaries_range(developer_id, first_day, last_date)

    # Aggregate
    total_requests = 0
    total_errors = 0
    total_cost = 0.0
    by_endpoint_group: Dict[str, int] = {}
    by_resource_type: Dict[str, float] = {}

    for daily in daily_summaries:
        total_requests += daily.total_requests
        total_errors += daily.total_errors
        total_cost += daily.total_cost

        for group, count in daily.by_endpoint_group.items():
            by_endpoint_group[group] = by_endpoint_group.get(group, 0) + count

        for rt, units in daily.by_resource_type.items():
            by_resource_type[rt] = by_resource_type.get(rt, 0.0) + units

    summary = MonthlyUsageSummary(
        month=month,
        developer_id=developer_id,
        total_requests=total_requests,
        total_errors=total_errors,
        total_cost=total_cost,
        by_endpoint_group=by_endpoint_group,
        by_resource_type=by_resource_type,
        updated_at=datetime.utcnow(),
    )

    # Save to Firestore
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("usage_summaries")
        .document(f"monthly_{month}")
    )
    doc_ref.set(summary.model_dump())

    return summary


# ******************************************************
# ************** HELPER FUNCTIONS **********************
# ******************************************************


def _get_date_range(start_date: str, end_date: str) -> List[str]:
    """
    Generate a list of date strings between start and end dates.

    Args:
        start_date: Start date (YYYY-MM-DD)
        end_date: End date (YYYY-MM-DD)

    Returns:
        List of date strings
    """
    from datetime import datetime, timedelta

    start = datetime.strptime(start_date, "%Y-%m-%d")
    end = datetime.strptime(end_date, "%Y-%m-%d")

    dates = []
    current = start
    while current <= end:
        dates.append(current.strftime("%Y-%m-%d"))
        current += timedelta(days=1)

    return dates


def delete_old_logs(developer_id: str, before_date: str) -> int:
    """
    Delete log entries older than a specific date.

    Useful for data retention policies.

    Args:
        developer_id: The developer ID
        before_date: Delete logs before this date (YYYY-MM-DD)

    Returns:
        Number of documents deleted
    """
    from datetime import datetime, timedelta

    # List all daily log collections
    daily_logs_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_logs_daily")
    )

    docs = daily_logs_ref.stream()
    deleted_count = 0

    for doc in docs:
        date_str = doc.id
        if date_str < before_date:
            # Delete all logs in this collection
            logs_ref = daily_logs_ref.document(date_str).collection("logs")
            batch = db.batch()
            count = 0

            for log_doc in logs_ref.stream():
                batch.delete(log_doc.reference)
                count += 1
                if count >= 500:
                    batch.commit()
                    batch = db.batch()
                    count = 0

            if count > 0:
                batch.commit()

            # Delete the daily document itself
            daily_logs_ref.document(date_str).delete()

            # Also delete the daily summary
            summary_ref = (
                db.collection("developer_data")
                .document(developer_id)
                .collection("usage_summaries")
                .document(f"daily_{date_str}")
            )
            if summary_ref.get().exists:
                summary_ref.delete()

            deleted_count += 1

    return deleted_count
