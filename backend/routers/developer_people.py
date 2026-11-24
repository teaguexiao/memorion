"""
Developer API - People/Contacts endpoints

All data is tenant-isolated under developer_data/{developer_id}/users/{external_user_id}/people
"""

from datetime import datetime
from typing import List, Optional, Dict, Any
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile, File
from pydantic import BaseModel, Field

import database.developer_data as dev_db
from dependencies import get_developer_id_from_api_key
from utils.other.storage import (
    get_developer_person_speech_samples,
    get_developer_person_speech_sample_count,
    get_developer_people_speech_sample_counts,
    upload_developer_person_speech_sample_from_file,
    delete_developer_person_speech_sample,
    delete_all_developer_person_speech_samples,
)

router = APIRouter()


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class PersonCreate(BaseModel):
    external_user_id: str = Field(..., description="External user identifier")
    name: str = Field(..., min_length=1, description="Person's name")
    metadata: Dict[str, Any] = Field(default={}, description="Additional metadata")


class PersonUpdate(BaseModel):
    name: Optional[str] = Field(None, description="New name")
    metadata: Optional[Dict[str, Any]] = Field(None, description="Metadata to merge")


class PersonResponse(BaseModel):
    id: str
    name: str
    metadata: Dict[str, Any]
    created_at: datetime
    updated_at: datetime
    # 这个人是怎么来的：speaker_mapping / mention / manual，老文档是 None（未知）。
    # 见 developer_data.PERSON_SOURCE_*。
    source: Optional[str] = None
    speech_samples: Optional[List[str]] = []
    # 样本**条数**，和 speech_samples 是否被请求无关。列表界面只需要这个数字，而算它
    # 不用逐人列 GCS —— 见 get_developer_people_speech_sample_counts 的注释。
    speech_samples_count: int = 0
    speech_samples_duration: Optional[float] = 0.0


class SpeechSampleResponse(BaseModel):
    sample_id: str
    sample_url: str


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.get("/v1/people", response_model=List[PersonResponse], tags=["developer-api-people"])
async def list_people(
    external_user_id: str = Query(..., description="External user identifier"),
    limit: int = Query(default=100, ge=1, le=500, description="Maximum people to return"),
    offset: int = Query(default=0, ge=0, description="Number of people to skip"),
    include_speech_samples: bool = Query(default=False, description="Include speech sample URLs"),
    include_mentions: bool = Query(
        default=False,
        description="Include people who were only mentioned in a conversation and never spoke",
    ),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    List people/contacts for a user.

    ⚠️ **`include_speech_samples=true` 在这个端点上很贵，通常也不是你要的。** 它对每个
    person 各做一次 GCS 列举 + 逐 blob 签名：833 人的账号上单页实测 15.65s，而
    `false` 是 2.38s。样本条数**无论如何都会返回**（`speech_samples_count`，一次整体
    列举算出），所以「列表显示 N 段样本、点进详情才取 URL」的界面不需要打开这个开关 ——
    详情用 `GET /v1/people/{id}?include_speech_samples=true`，那只是一个人的代价。

    ⚠️ **`include_mentions` 默认 `false`，这是有意的默认值反转。** 转录稿里只是被
    「提到」过的名字也会建成 Person（`source='mention'`），实测某账号 833 个人里 802 个
    是这么来的，真说过话的只有 31 个 —— 名单里全是噪声时，这一页和「标记说话人」的
    选择器都没法用了。
    """
    people = dev_db.get_people(
        developer_id=developer_id,
        external_user_id=external_user_id,
        limit=limit,
        offset=offset,
        include_mentions=include_mentions,
    )

    # 只在**不带样本**时才整体列一次。带样本的那条路下面已经逐人列过了，直接数就行 ——
    # 否则老客户端（2.0.2 及以前，`getAllPeople` 默认 `include_speech_samples=true`）
    # 会同时付两份 GCS 列举：又贵一点，而它本来就是最慢的那条路。
    counts = {} if include_speech_samples else get_developer_people_speech_sample_counts(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )

    result = []
    for person in people:
        person_dict = dict(person)
        if include_speech_samples:
            person_dict['speech_samples'] = get_developer_person_speech_samples(
                developer_id=developer_id,
                external_user_id=external_user_id,
                person_id=person['id'],
            )
            person_dict['speech_samples_count'] = len(person_dict['speech_samples'])
        else:
            person_dict['speech_samples'] = []
            person_dict['speech_samples_count'] = counts.get(person['id'], 0)
        result.append(person_dict)

    return result


@router.post("/v1/people", response_model=PersonResponse, status_code=201, tags=["developer-api-people"])
async def create_person(
    person_data: PersonCreate,
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Create a new person/contact for a user.

    ⚠️ **同名已存在时复用并升级那一条，不新建。** 名单默认藏掉了只被提到过的人
    （`include_mentions=False`），所以用户在「标记说话人」里手打一个名字时，很可能这个
    名字**已经**作为 mention 存在、甚至已被归档 —— 直接新建就会出现两条同名记录，声纹
    样本还会分散到两个 person_id 上。提取路径本来就是按名字去重的，名字唯一是既有模型。
    """
    name_index = dev_db.get_people_name_index(
        developer_id=developer_id,
        external_user_id=person_data.external_user_id,
    )
    existing = name_index.get(person_data.name.strip().lower())
    if existing:
        promoted = dev_db.restore_person(
            developer_id=developer_id,
            external_user_id=person_data.external_user_id,
            person_id=existing['id'],
            source=dev_db.PERSON_SOURCE_MANUAL,
        )
        if promoted:
            if person_data.metadata:
                promoted = dev_db.update_person(
                    developer_id=developer_id,
                    external_user_id=person_data.external_user_id,
                    person_id=existing['id'],
                    metadata=person_data.metadata,
                )
            return promoted

    person = dev_db.create_person(
        developer_id=developer_id,
        external_user_id=person_data.external_user_id,
        name=person_data.name,
        metadata=person_data.metadata,
        source=dev_db.PERSON_SOURCE_MANUAL,
    )

    return person


@router.get("/v1/people/{person_id}", response_model=PersonResponse, tags=["developer-api-people"])
async def get_person(
    person_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    include_speech_samples: bool = Query(default=False, description="Include speech sample URLs"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get a single person by ID.
    """
    person = dev_db.get_person(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
    )

    if not person:
        raise HTTPException(status_code=404, detail="Person not found")

    person_dict = dict(person)
    if include_speech_samples:
        person_dict['speech_samples'] = get_developer_person_speech_samples(
            developer_id=developer_id,
            external_user_id=external_user_id,
            person_id=person_id,
        )
        # 已经列过这个人的样本了，直接数，不再多打一次 GCS。
        person_dict['speech_samples_count'] = len(person_dict['speech_samples'])
    else:
        person_dict['speech_samples'] = []
        person_dict['speech_samples_count'] = get_developer_person_speech_sample_count(
            developer_id=developer_id,
            external_user_id=external_user_id,
            person_id=person_id,
        )

    return person_dict


@router.patch("/v1/people/{person_id}", response_model=PersonResponse, tags=["developer-api-people"])
async def update_person(
    person_id: str,
    person_data: PersonUpdate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update a person.
    """
    person = dev_db.update_person(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
        name=person_data.name,
        metadata=person_data.metadata,
    )

    if not person:
        raise HTTPException(status_code=404, detail="Person not found")

    return person


@router.delete("/v1/people/{person_id}", status_code=204, tags=["developer-api-people"])
def delete_person(
    person_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete a person and all their speech samples.

    Sync `def` on purpose — see the note on
    `developer_conversations.process_conversation`. Deleting the samples means
    listing and deleting GCS blobs, which scales with how much this person was
    enrolled; none of it is awaited, so `async def` ran it on the event loop.
    """
    success = dev_db.delete_person(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Person not found")

    # Delete all speech samples for this person
    delete_all_developer_person_speech_samples(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
    )

    return


# ******************************************************
# ****************** SPEECH SAMPLES ********************
# ******************************************************


@router.get("/v1/people/{person_id}/speech-samples", response_model=List[str], tags=["developer-api-people"])
async def list_person_speech_samples(
    person_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    List speech samples for a person.
    """
    # Verify person exists
    person = dev_db.get_person(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
    )
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")

    return get_developer_person_speech_samples(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
    )


@router.post("/v1/people/{person_id}/speech-samples", response_model=SpeechSampleResponse, status_code=201, tags=["developer-api-people"])
async def upload_person_speech_sample(
    person_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    audio_file: UploadFile = File(..., description="Audio file (WAV format)"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Upload a speech sample for a person.
    """
    import os
    import tempfile

    # Verify person exists
    person = dev_db.get_person(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
    )
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")

    # Generate sample ID
    sample_id = str(uuid.uuid4())[:8]

    # Save uploaded file temporarily
    temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.wav')
    try:
        content = await audio_file.read()
        temp_file.write(content)
        temp_file.close()

        result = upload_developer_person_speech_sample_from_file(
            developer_id=developer_id,
            external_user_id=external_user_id,
            person_id=person_id,
            file_path=temp_file.name,
            sample_id=sample_id,
        )

        return result
    finally:
        os.unlink(temp_file.name)


@router.delete("/v1/people/{person_id}/speech-samples/{sample_id}", status_code=204, tags=["developer-api-people"])
def delete_person_speech_sample(
    person_id: str,
    sample_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete a speech sample for a person.

    Sync `def` on purpose — see `delete_person` above.
    """
    # Verify person exists
    person = dev_db.get_person(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
    )
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")

    success = delete_developer_person_speech_sample(
        developer_id=developer_id,
        external_user_id=external_user_id,
        person_id=person_id,
        sample_id=sample_id,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Speech sample not found")

    return
