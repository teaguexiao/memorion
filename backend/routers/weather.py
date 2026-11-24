import logging
from datetime import datetime, timezone
from typing import Optional

import requests
from fastapi import APIRouter, Depends

import database.developer_data as dev_db
from database.redis_db import get_generic_cache, set_generic_cache, get_cached_user_geolocation
from models.weather_card import WeatherSnapshot
from utils.other import endpoints as auth

router = APIRouter()
logger = logging.getLogger(__name__)

_CACHE_TTL = 60 * 60
_WEATHER_CODES = {
    0: 'sunny',
    1: 'cloudy',
    2: 'cloudy',
    3: 'cloudy',
    45: 'wind',
    48: 'wind',
    51: 'rain',
    53: 'rain',
    55: 'rain',
    61: 'rain',
    63: 'rain',
    65: 'rain',
    71: 'snow',
    73: 'snow',
    75: 'snow',
    80: 'rain',
    81: 'rain',
    82: 'storm',
    95: 'storm',
    96: 'storm',
    99: 'storm',
}


def _cache_key(uid: str, lat: Optional[float], lng: Optional[float]) -> str:
    if lat is None or lng is None:
        return f'weather:{uid}:fallback'
    return f'weather:{uid}:{lat:.3f}:{lng:.3f}'



def _fallback_snapshot() -> WeatherSnapshot:
    return WeatherSnapshot(condition='sunny', temperature_c=24, is_fallback=True)



def _normalize_geo(geo: Optional[dict]) -> tuple[Optional[float], Optional[float]]:
    if not geo:
        return None, None
    try:
        return float(geo.get('latitude')), float(geo.get('longitude'))
    except Exception:
        return None, None



def _fetch_weather(lat: float, lng: float) -> Optional[WeatherSnapshot]:
    url = 'https://api.open-meteo.com/v1/forecast'
    params = {
        'latitude': lat,
        'longitude': lng,
        'current': 'temperature_2m,weather_code',
        'timezone': 'auto',
        'forecast_days': 1,
    }
    try:
        response = requests.get(url, params=params, timeout=6)
        if response.status_code != 200:
            logger.warning('[weather] open-meteo status=%s body=%s', response.status_code, response.text[:200])
            return None
        payload = response.json().get('current') or {}
        code = int(payload.get('weather_code', 0))
        condition = _WEATHER_CODES.get(code, 'cloudy')
        temp = int(round(float(payload.get('temperature_2m', 24))))
        return WeatherSnapshot(condition=condition, temperature_c=temp, is_fallback=False)
    except Exception as exc:
        logger.warning('[weather] fetch failed: %s', exc)
        return None


@router.get('/v1/weather', tags=['home'], response_model=WeatherSnapshot)
def get_weather_snapshot(ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    geo = get_cached_user_geolocation(uid) or (dev_db.get_user_geolocation(developer_id, uid) if developer_id else None)
    lat, lng = _normalize_geo(geo)
    cache_key = _cache_key(uid, lat, lng)
    cached = get_generic_cache(cache_key)
    if cached:
        return WeatherSnapshot(**cached)

    snapshot = None
    if lat is not None and lng is not None:
        snapshot = _fetch_weather(lat, lng)
    if snapshot is None:
        snapshot = _fallback_snapshot()

    snapshot = WeatherSnapshot(
        condition=snapshot.condition,
        temperature_c=snapshot.temperature_c,
        is_fallback=snapshot.is_fallback,
        updated_at=datetime.now(timezone.utc),
    )
    payload = snapshot.model_dump(mode='json')
    set_generic_cache(cache_key, payload, ttl=_CACHE_TTL)
    return snapshot
