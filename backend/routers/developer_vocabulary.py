"""
Developer API - Vocabulary (custom terms) endpoints

All data is tenant-isolated under
developer_data/{developer_id}/users/{external_user_id}/vocabulary

Phase 0: store + manage custom terms (add / list / delete; update supported by
the backend but not yet surfaced in the app). These terms are collected now so a
future phase can feed them into the summary LLM (as a correction glossary) and/or
STT hotwords to improve transcription/understanding accuracy.
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


class VocabularyCreate(BaseModel):
    external_user_id: str = Field(..., description="External user identifier")
    term: str = Field(..., min_length=1, description="Vocabulary term/word")
    metadata: Dict[str, Any] = Field(default={}, description="Additional metadata")


class VocabularyUpdate(BaseModel):
    term: Optional[str] = Field(None, min_length=1, description="New term")
    metadata: Optional[Dict[str, Any]] = Field(None, description="Metadata to merge")


class VocabularyResponse(BaseModel):
    id: str
    term: str
    metadata: Dict[str, Any]
    created_at: datetime
    updated_at: datetime


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.get("/v1/vocabulary", response_model=List[VocabularyResponse], tags=["developer-api-vocabulary"])
async def list_vocabulary(
    external_user_id: str = Query(..., description="External user identifier"),
    limit: int = Query(default=100, ge=1, le=500, description="Maximum entries to return"),
    offset: int = Query(default=0, ge=0, description="Number of entries to skip"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    List vocabulary entries for a user (newest first).
    """
    return dev_db.get_vocabulary(
        developer_id=developer_id,
        external_user_id=external_user_id,
        limit=limit,
        offset=offset,
    )


@router.post("/v1/vocabulary", response_model=VocabularyResponse, status_code=201, tags=["developer-api-vocabulary"])
async def create_vocabulary(
    data: VocabularyCreate,
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Create a vocabulary entry. If the same term already exists, the existing
    entry is returned (no duplicate is inserted).
    """
    return dev_db.create_vocabulary_entry(
        developer_id=developer_id,
        external_user_id=data.external_user_id,
        term=data.term,
        metadata=data.metadata,
    )


@router.patch("/v1/vocabulary/{entry_id}", response_model=VocabularyResponse, tags=["developer-api-vocabulary"])
async def update_vocabulary(
    entry_id: str,
    data: VocabularyUpdate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update a vocabulary entry (term and/or metadata).
    """
    entry = dev_db.update_vocabulary_entry(
        developer_id=developer_id,
        external_user_id=external_user_id,
        entry_id=entry_id,
        term=data.term,
        metadata=data.metadata,
    )

    if not entry:
        raise HTTPException(status_code=404, detail="Vocabulary entry not found")

    return entry


@router.delete("/v1/vocabulary/{entry_id}", status_code=204, tags=["developer-api-vocabulary"])
async def delete_vocabulary(
    entry_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete a vocabulary entry.
    """
    success = dev_db.delete_vocabulary_entry(
        developer_id=developer_id,
        external_user_id=external_user_id,
        entry_id=entry_id,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Vocabulary entry not found")

    return
