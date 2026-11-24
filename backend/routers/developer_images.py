"""
Developer API - Images endpoints

All data is tenant-isolated under developer_data/{developer_id}/users/{external_user_id}/images

Image files are stored in GCS bucket: BUCKET_CONVERSATION_PHOTOS
"""

import asyncio
import base64
import json
import logging
from datetime import datetime
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request, UploadFile, File, Form
from pydantic import BaseModel, Field

import database.developer_data as dev_db
from dependencies import get_developer_id_from_api_key
from utils.logging.context import ensure_billing_context
from utils.llm.image_description import ImageDescriptionObject, describe_image_with_gemini
from utils.other.storage import (
    upload_conversation_photo,
    upload_conversation_photo_base64,
    get_conversation_photo_signed_url_from_path,
    delete_conversation_photo_by_path,
)

router = APIRouter()
logger = logging.getLogger(__name__)

# Maximum file size: 10MB
MAX_FILE_SIZE = 10 * 1024 * 1024


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class ImageUploadBase64(BaseModel):
    external_user_id: str = Field(..., description="External user identifier")
    base64_data: str = Field(..., description="Base64 encoded image data")
    conversation_id: Optional[str] = Field(None, description="Associated conversation ID")
    generate_description: bool = Field(default=False, description="Generate VLM description")
    metadata: Dict[str, Any] = Field(default={}, description="Additional metadata")


class ImageUpdate(BaseModel):
    description: Optional[str] = Field(None, description="Update description (JSON string)")
    conversation_id: Optional[str] = Field(None, description="Update conversation association")
    metadata: Optional[Dict[str, Any]] = Field(None, description="Metadata to merge")


class ImageResponse(BaseModel):
    id: str
    gcs_path: str
    content_type: str
    size_bytes: int
    description: Optional[str] = None
    conversation_id: Optional[str] = None
    metadata: Dict[str, Any]
    created_at: datetime
    updated_at: datetime


class ImageUrlResponse(BaseModel):
    image_url: Optional[str] = None
    expires_in_minutes: int = 15


class ImageDescribeResponse(BaseModel):
    """Response for describe endpoint"""
    id: str
    description: ImageDescriptionObject
    raw_json: str = Field(description="Raw JSON string of the description")
    created_at: datetime
    updated_at: datetime


# ******************************************************
# ****************** HELPERS ***************************
# ******************************************************


def _generate_uid(developer_id: str, external_user_id: str) -> str:
    """Generate a unique identifier for GCS storage path."""
    return f"dev_{developer_id}_{external_user_id}"


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.get("/v1/images", response_model=List[ImageResponse], tags=["developer-api-images"])
async def list_images(
    external_user_id: str = Query(..., description="External user identifier"),
    conversation_id: Optional[str] = Query(None, description="Filter by conversation ID"),
    limit: int = Query(default=100, ge=1, le=500, description="Maximum images to return"),
    offset: int = Query(default=0, ge=0, description="Number of images to skip"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    List images for a user.

    Supports pagination and optional filtering by conversation.
    """
    images = dev_db.list_images(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        limit=limit,
        offset=offset,
    )

    return images


@router.post("/v1/images", response_model=ImageResponse, status_code=201, tags=["developer-api-images"])
async def upload_image(
    request: Request,
    file: UploadFile = File(...),
    external_user_id: str = Form(...),
    conversation_id: Optional[str] = Form(None),
    generate_description: bool = Form(False),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Upload an image file.

    Supports JPEG and PNG formats. Maximum file size is 10MB.
    Optionally generates a structured VLM description using Gemini.
    """
    # Validate content type
    content_type = file.content_type
    if content_type not in ["image/jpeg", "image/png"]:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported content type: {content_type}. Only image/jpeg and image/png are supported."
        )

    # Read file content
    content = await file.read()

    # Validate file size
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(
            status_code=400,
            detail=f"File too large. Maximum size is {MAX_FILE_SIZE // (1024 * 1024)}MB."
        )

    # Generate unique identifiers
    import uuid
    image_id = str(uuid.uuid4())
    uid = _generate_uid(developer_id, external_user_id)

    # Upload to GCS
    try:
        gcs_path = upload_conversation_photo(
            image_data=content,
            uid=uid,
            image_id=image_id,
            content_type=content_type,
        )
    except Exception as e:
        logger.error(f"Failed to upload image to GCS: {e}")
        raise HTTPException(status_code=500, detail="Failed to upload image")

    # Generate description if requested
    description = None
    if generate_description:
        try:
            image_b64 = base64.b64encode(content).decode('utf-8')
            desc_obj = await asyncio.wait_for(
                describe_image_with_gemini(image_b64),
                timeout=60.0
            )
            description = desc_obj.model_dump_json()
        except asyncio.TimeoutError:
            logger.warning(f"VLM description timeout for image {image_id}")
        except Exception as e:
            logger.warning(f"Failed to generate description for image {image_id}: {e}")

    # Create database record
    try:
        image_data = dev_db.create_image(
            developer_id=developer_id,
            external_user_id=external_user_id,
            gcs_path=gcs_path,
            content_type=content_type,
            size_bytes=len(content),
            description=description,
            conversation_id=conversation_id,
            metadata={},
        )
    except Exception as e:
        # Cleanup GCS on DB failure
        try:
            delete_conversation_photo_by_path(gcs_path)
        except Exception:
            pass
        logger.error(f"Failed to create image record: {e}")
        raise HTTPException(status_code=500, detail="Failed to create image record")

    # Set billing context for API logging
    billing_context = ensure_billing_context(request)
    billing_context.set_storage_usage(len(content))
    billing_context.external_user_id = external_user_id
    if generate_description:
        # Also count VLM usage
        billing_context.set_vlm_usage(1)

    return image_data


@router.post("/v1/images/base64", response_model=ImageResponse, status_code=201, tags=["developer-api-images"])
async def upload_image_base64(
    image_data: ImageUploadBase64,
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Upload an image using base64 encoding.

    Accepts base64 data with or without data URI prefix.
    Example: "data:image/jpeg;base64,/9j/4AAQ..." or just "/9j/4AAQ..."
    """
    import uuid

    # Decode and validate size
    try:
        if image_data.base64_data.startswith('data:'):
            _, b64_content = image_data.base64_data.split(',', 1)
        else:
            b64_content = image_data.base64_data
        content = base64.b64decode(b64_content)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid base64 data: {e}")

    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(
            status_code=400,
            detail=f"Image too large. Maximum size is {MAX_FILE_SIZE // (1024 * 1024)}MB."
        )

    # Detect content type
    if content[:8] == b'\x89PNG\r\n\x1a\n':
        content_type = 'image/png'
    elif content[:2] == b'\xff\xd8':
        content_type = 'image/jpeg'
    else:
        raise HTTPException(status_code=400, detail="Invalid image format. Only JPEG and PNG are supported.")

    # Generate unique identifiers
    image_id = str(uuid.uuid4())
    uid = _generate_uid(developer_id, image_data.external_user_id)

    # Upload to GCS
    try:
        gcs_path = upload_conversation_photo(
            image_data=content,
            uid=uid,
            image_id=image_id,
            content_type=content_type,
        )
    except Exception as e:
        logger.error(f"Failed to upload image to GCS: {e}")
        raise HTTPException(status_code=500, detail="Failed to upload image")

    # Generate description if requested
    description = None
    if image_data.generate_description:
        try:
            desc_obj = await asyncio.wait_for(
                describe_image_with_gemini(b64_content),
                timeout=60.0
            )
            description = desc_obj.model_dump_json()
        except asyncio.TimeoutError:
            logger.warning(f"VLM description timeout for image {image_id}")
        except Exception as e:
            logger.warning(f"Failed to generate description for image {image_id}: {e}")

    # Create database record
    try:
        db_image = dev_db.create_image(
            developer_id=developer_id,
            external_user_id=image_data.external_user_id,
            gcs_path=gcs_path,
            content_type=content_type,
            size_bytes=len(content),
            description=description,
            conversation_id=image_data.conversation_id,
            metadata=image_data.metadata,
        )
    except Exception as e:
        try:
            delete_conversation_photo_by_path(gcs_path)
        except Exception:
            pass
        logger.error(f"Failed to create image record: {e}")
        raise HTTPException(status_code=500, detail="Failed to create image record")

    return db_image


@router.get("/v1/images/{image_id}", response_model=ImageResponse, tags=["developer-api-images"])
async def get_image(
    image_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get image metadata by ID.

    Returns image metadata including GCS path, size, content type, and description.
    Use GET /v1/images/{image_id}/url to get a download URL.
    """
    image = dev_db.get_image(
        developer_id=developer_id,
        external_user_id=external_user_id,
        image_id=image_id,
    )

    if not image:
        raise HTTPException(status_code=404, detail="Image not found")

    return image


@router.get("/v1/images/{image_id}/url", response_model=ImageUrlResponse, tags=["developer-api-images"])
def get_image_url(
    image_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get a signed download URL for an image.

    The URL is valid for 15 minutes. Returns null if image not found in storage.

    Sync `def` on purpose — see the note on
    `developer_conversations.process_conversation`. Firestore read plus a blocking
    GCS call, no `await` anywhere, so `async def` only bought event-loop time.
    """
    image = dev_db.get_image(
        developer_id=developer_id,
        external_user_id=external_user_id,
        image_id=image_id,
    )

    if not image:
        raise HTTPException(status_code=404, detail="Image not found")

    gcs_path = image.get("gcs_path")
    if not gcs_path:
        return ImageUrlResponse(image_url=None, expires_in_minutes=15)

    signed_url = get_conversation_photo_signed_url_from_path(gcs_path, minutes=15)

    return ImageUrlResponse(
        image_url=signed_url if signed_url else None,
        expires_in_minutes=15
    )


@router.patch("/v1/images/{image_id}", response_model=ImageResponse, tags=["developer-api-images"])
async def update_image(
    image_id: str,
    image_update: ImageUpdate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update image metadata.

    Only provided fields will be updated. Metadata is merged with existing values.
    """
    image = dev_db.update_image(
        developer_id=developer_id,
        external_user_id=external_user_id,
        image_id=image_id,
        description=image_update.description,
        conversation_id=image_update.conversation_id,
        metadata=image_update.metadata,
    )

    if not image:
        raise HTTPException(status_code=404, detail="Image not found")

    return image


@router.delete("/v1/images/{image_id}", status_code=204, tags=["developer-api-images"])
def delete_image(
    image_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete an image.

    Removes both the database record and the file from GCS storage.

    Sync `def` on purpose — see `get_image_url` above.
    """
    gcs_path = dev_db.delete_image(
        developer_id=developer_id,
        external_user_id=external_user_id,
        image_id=image_id,
    )

    if gcs_path is None:
        raise HTTPException(status_code=404, detail="Image not found")

    # Delete from GCS
    try:
        delete_conversation_photo_by_path(gcs_path)
    except Exception as e:
        logger.warning(f"Failed to delete image from GCS: {e}")

    return None


@router.post("/v1/images/{image_id}/describe", response_model=ImageDescribeResponse, tags=["developer-api-images"])
async def generate_image_description(
    image_id: str,
    request: Request,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Generate or regenerate a structured VLM description for an image using Gemini.

    Downloads the image from GCS and processes it with Gemini Vision model.
    Returns a structured JSON description with objects, people, text, scene, etc.
    Updates the image record with the new description.
    """
    image = dev_db.get_image(
        developer_id=developer_id,
        external_user_id=external_user_id,
        image_id=image_id,
    )

    if not image:
        raise HTTPException(status_code=404, detail="Image not found")

    gcs_path = image.get("gcs_path")
    if not gcs_path:
        raise HTTPException(status_code=400, detail="Image has no associated file")

    # Get signed URL and download image
    signed_url = get_conversation_photo_signed_url_from_path(gcs_path, minutes=5)
    if not signed_url:
        raise HTTPException(status_code=404, detail="Image file not found in storage")

    # Download and encode to base64
    import httpx
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(signed_url)
            response.raise_for_status()
            image_bytes = response.content
    except Exception as e:
        logger.error(f"Failed to download image: {e}")
        raise HTTPException(status_code=500, detail="Failed to download image")

    # Generate structured description using Gemini
    try:
        image_b64 = base64.b64encode(image_bytes).decode('utf-8')
        description_obj = await asyncio.wait_for(
            describe_image_with_gemini(image_b64),
            timeout=60.0
        )
    except asyncio.TimeoutError:
        raise HTTPException(status_code=504, detail="VLM processing timeout")
    except Exception as e:
        logger.error(f"VLM processing error: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to generate description: {str(e)}")

    # Convert to JSON string for storage
    description_json = description_obj.model_dump_json()

    # Update image with new description
    updated_image = dev_db.update_image(
        developer_id=developer_id,
        external_user_id=external_user_id,
        image_id=image_id,
        description=description_json,
    )

    # Set billing context for API logging (VLM request)
    billing_context = ensure_billing_context(request)
    billing_context.set_vlm_usage(1)
    billing_context.external_user_id = external_user_id

    return ImageDescribeResponse(
        id=image_id,
        description=description_obj,
        raw_json=description_json,
        created_at=updated_image.get("created_at"),
        updated_at=updated_image.get("updated_at"),
    )
