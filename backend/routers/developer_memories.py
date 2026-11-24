"""
Developer API - Memories endpoints

All data is tenant-isolated under developer_data/{developer_id}/users/{external_user_id}/memories
"""

from datetime import datetime
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

import database.developer_data as dev_db
from dependencies import get_developer_id_from_api_key

router = APIRouter()


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class MemoryCreate(BaseModel):
    # App 的 createMemoryServer 只发 {content, visibility}，external_user_id 走 query
    # 参数（makeApiCall 统一追加），所以这里不能必填，否则 App 手动添加直接 422。
    external_user_id: Optional[str] = Field(None, description="External user identifier (or pass as query param)")
    content: str = Field(..., min_length=1, description="Memory content")
    category: str = Field(default="interesting", description="Memory category")
    tags: List[str] = Field(default=[], description="Tags for the memory")
    metadata: Dict[str, Any] = Field(default={}, description="Additional metadata")
    visibility: str = Field(default="private", description="Memory visibility (private or public)")


class MemoryUpdate(BaseModel):
    content: Optional[str] = Field(None, description="New content")
    category: Optional[str] = Field(None, description="New category")
    tags: Optional[List[str]] = Field(None, description="New tags")
    metadata: Optional[Dict[str, Any]] = Field(None, description="Metadata to merge")
    visibility: Optional[str] = Field(None, description="New visibility")


class MemoryResponse(BaseModel):
    id: str
    content: str
    category: str
    tags: List[str] = []
    metadata: Dict[str, Any] = {}
    visibility: str = "private"
    reviewed: bool = False
    # user_review：用户对 LLM 提取事实的裁决。True=「没错」/ False=「不对」（否决）/
    # None=还没表态（待确认）。⚠️ response_model 会静默滤掉未声明的字段，App 靠这个
    # 字段区分待确认与已确认，所以必须显式列出（对齐 ActionItem.confirmed 踩过的坑）。
    user_review: Optional[bool] = None
    # 用户手动添加的事实天然可信，App 里单独分组展示。response_model 会静默滤掉
    # 未声明的字段，所以这个字段必须在这里列出来。
    manually_added: bool = False
    deleted: bool = False
    created_at: datetime
    updated_at: datetime


class MemorySearchRequest(BaseModel):
    external_user_id: str = Field(..., description="External user identifier")
    query: str = Field(..., min_length=1, description="Search query")
    limit: int = Field(default=10, ge=1, le=100, description="Maximum results")


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.get("/v1/memories", response_model=List[MemoryResponse], tags=["developer-api-memories"])
async def list_memories(
    external_user_id: str = Query(..., description="External user identifier"),
    limit: int = Query(default=100, ge=1, le=500, description="Maximum memories to return"),
    offset: int = Query(default=0, ge=0, description="Number of memories to skip"),
    categories: Optional[str] = Query(None, description="Comma-separated categories to filter"),
    tags: Optional[str] = Query(None, description="Comma-separated tags to filter (any match)"),
    status: str = Query(
        default="confirmed",
        description="Review status filter: 'confirmed' (default, 用户确认过的事实), "
        "'pending' (LLM 提取、待用户确认), or 'all'",
    ),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    List memories for a user.

    Supports pagination and filtering by categories, tags, and review status.
    """
    if status not in ("confirmed", "pending", "all"):
        raise HTTPException(status_code=400, detail="Invalid status. Must be 'confirmed', 'pending', or 'all'")

    category_list = [c.strip() for c in categories.split(",")] if categories else None
    tag_list = [t.strip() for t in tags.split(",")] if tags else None

    memories = dev_db.get_memories(
        developer_id=developer_id,
        external_user_id=external_user_id,
        limit=limit,
        offset=offset,
        categories=category_list,
        tags=tag_list,
        status=status,
    )

    return memories


@router.post("/v1/memories", response_model=MemoryResponse, status_code=201, tags=["developer-api-memories"])
async def create_memory(
    memory_data: MemoryCreate,
    external_user_id: Optional[str] = Query(None, description="External user identifier (query param)"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Create a new memory for a user.

    The memory is stored under the developer's tenant-isolated data.

    Note: external_user_id can be passed either in request body or as query parameter.
    """
    user_id = memory_data.external_user_id or external_user_id
    if not user_id:
        raise HTTPException(status_code=400, detail="external_user_id is required (in body or query param)")

    # Validate visibility
    if memory_data.visibility not in ["private", "public"]:
        raise HTTPException(status_code=400, detail="Invalid visibility value. Must be 'private' or 'public'")

    memory = dev_db.create_memory(
        developer_id=developer_id,
        external_user_id=user_id,
        content=memory_data.content,
        category=memory_data.category,
        tags=memory_data.tags,
        metadata=memory_data.metadata,
        visibility=memory_data.visibility,
        # 这条端点只有用户主动写入才会走到（提取流程走 save_memories_batch），
        # 所以一律标 manually_added，App 才能把「你告诉它的」单独分组。
        manually_added=True,
    )

    return memory


@router.get("/v1/memories/{memory_id}", response_model=MemoryResponse, tags=["developer-api-memories"])
async def get_memory(
    memory_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get a single memory by ID.
    """
    memory = dev_db.get_memory(
        developer_id=developer_id,
        external_user_id=external_user_id,
        memory_id=memory_id,
    )

    if not memory:
        raise HTTPException(status_code=404, detail="Memory not found")

    return memory


@router.patch("/v1/memories/{memory_id}", response_model=MemoryResponse, tags=["developer-api-memories"])
async def update_memory(
    memory_id: str,
    memory_data: Optional[MemoryUpdate] = None,
    external_user_id: str = Query(..., description="External user identifier"),
    value: Optional[str] = Query(None, description="Quick edit: new content value"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update a memory.

    Two ways to update:
    1. Pass `value` query param to quickly edit content only
    2. Pass JSON body with fields to update (content, category, tags, metadata, visibility)

    Metadata is merged with existing when using JSON body.
    """
    # Support quick edit via query param (for app compatibility)
    if value is not None:
        success = dev_db.edit_memory_content(
            developer_id=developer_id,
            external_user_id=external_user_id,
            memory_id=memory_id,
            content=value,
        )
        if not success:
            raise HTTPException(status_code=404, detail="Memory not found")

        # Get and return updated memory
        memory = dev_db.get_memory(
            developer_id=developer_id,
            external_user_id=external_user_id,
            memory_id=memory_id,
        )
        return memory

    # Standard update via JSON body
    if memory_data is None:
        raise HTTPException(status_code=400, detail="Either 'value' query param or JSON body required")

    memory = dev_db.update_memory(
        developer_id=developer_id,
        external_user_id=external_user_id,
        memory_id=memory_id,
        content=memory_data.content,
        category=memory_data.category,
        tags=memory_data.tags,
        metadata=memory_data.metadata,
        visibility=memory_data.visibility,
    )

    if not memory:
        raise HTTPException(status_code=404, detail="Memory not found")

    return memory


@router.delete("/v1/memories/{memory_id}", status_code=204, tags=["developer-api-memories"])
async def delete_memory(
    memory_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete a memory.
    """
    success = dev_db.delete_memory(
        developer_id=developer_id,
        external_user_id=external_user_id,
        memory_id=memory_id,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Memory not found")

    return


@router.delete("/v1/memories", tags=["developer-api-memories"])
async def delete_all_memories(
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete all memories for a user.
    """
    deleted_count = dev_db.delete_all_memories(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )

    return {"status": "ok", "deleted_count": deleted_count}


@router.post("/v1/memories/{memory_id}/review", tags=["developer-api-memories"])
async def review_memory(
    memory_id: str,
    value: bool = Query(..., description="Review value (true or false)"),
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Review a memory (mark as reviewed or not).
    """
    success = dev_db.review_memory(
        developer_id=developer_id,
        external_user_id=external_user_id,
        memory_id=memory_id,
        value=value,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Memory not found")

    return {"status": "ok"}


@router.post("/v1/memories/search", response_model=List[MemoryResponse], tags=["developer-api-memories"])
async def search_memories(
    search_data: MemorySearchRequest,
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Search memories by content (literal, case-insensitive substring match).

    This is NOT semantic search: memories have no vector index of their own.
    Callers should pass a word expected to appear in the memory text and retry
    with synonyms. For meaning-based search over what the user actually said,
    use POST /v1/conversations/search, which is semantic.
    """
    memories = dev_db.search_memories(
        developer_id=developer_id,
        external_user_id=search_data.external_user_id,
        query=search_data.query,
        limit=search_data.limit,
    )

    return memories
