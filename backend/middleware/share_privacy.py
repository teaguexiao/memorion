"""CORS and non-cacheable responses only for the sharing surface, including errors."""
import os
import logging

logger = logging.getLogger(__name__)


def is_share_path(path):
    return path in ('/v1/shares', '/v1/share-resolve', '/v1/share-report') or path.startswith('/v1/shares/')


class SharePrivacyMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http' or not is_share_path(scope['path']):
            return await self.app(scope, receive, send)
        headers = dict(scope.get('headers', []))
        origin = headers.get(b'origin', b'').decode()
        allowed = {'https://memorion.me'} | {value.strip() for value in os.getenv('SHARE_ALLOWED_ORIGINS', '').split(',') if value.strip()}
        extra = [(b'cache-control', b'private, no-store, max-age=0'),
                 (b'x-robots-tag', b'noindex, nofollow, noarchive, nosnippet'),
                 (b'referrer-policy', b'no-referrer'), (b'x-content-type-options', b'nosniff'),
                 (b'vary', b'Origin')]
        if origin in allowed:
            extra += [(b'access-control-allow-origin', origin.encode()),
                      (b'access-control-allow-methods', b'POST, GET, DELETE, OPTIONS'),
                      (b'access-control-allow-headers', b'Content-Type, Authorization, X-Share-Token')]

        started = False

        async def protected(message):
            nonlocal started
            if message['type'] == 'http.response.start':
                started = True
                replaced = {k for k, _ in extra}
                message['headers'] = [(k, v) for k, v in message.get('headers', []) if k.lower() not in replaced] + extra
            await send(message)

        if scope['method'] == 'OPTIONS':
            await protected({'type': 'http.response.start', 'status': 204 if origin in allowed else 403, 'headers': []})
            return await send({'type': 'http.response.body', 'body': b''})
        # Bounded small JSON inputs. Count chunks as well as Content-Length.
        chunks, size = [], 0
        while True:
            msg = await receive()
            if msg['type'] == 'http.disconnect':
                return
            size += len(msg.get('body', b''))
            if size > 4096:
                await protected({'type': 'http.response.start', 'status': 413, 'headers': [(b'content-type', b'application/json')]})
                return await send({'type': 'http.response.body', 'body': b'{"detail":"Request too large"}'})
            chunks.append(msg.get('body', b''))
            if not msg.get('more_body'):
                break
        consumed = False

        async def replay():
            nonlocal consumed
            if not consumed:
                consumed = True
                return {'type': 'http.request', 'body': b''.join(chunks), 'more_body': False}
            return await receive()

        try:
            await self.app(scope, replay, protected)
        except Exception as exc:
            # Only a class name: no request, token, response body or traceback.
            logger.error('sharing_request_failed error_type=%s', type(exc).__name__)
            if started:
                raise
            # Firebase/Firestore failures must also carry no-store and CORS;
            # no exception detail or credential is returned/logged here.
            await protected({'type': 'http.response.start', 'status': 503, 'headers': [(b'content-type', b'application/json')]})
            await send({'type': 'http.response.body', 'body': b'{"detail":"Sharing temporarily unavailable"}'})
