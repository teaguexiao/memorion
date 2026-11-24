from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response
from fastapi import Request
import asyncio
import os


class TimeoutMiddleware(BaseHTTPMiddleware):
    """Caps request wall-clock time, answering 504 when the cap is hit.

    ⚠️ **A cap below an endpoint's own internal budget makes that endpoint
    structurally unable to succeed, and the failure is not local to it.**
    `POST /v1/conversations/upload-audio` blocks on a Soniox job that polls for
    up to 300s (plus ffmpeg, VAD and LLM processing) while this middleware
    defaulted every POST to 120s — so long recordings could only ever 504.
    Worse, the 504 is a lie by omission: `asyncio.wait_for` stops *awaiting* the
    handler, but the handler is a sync `def` running in the threadpool and keeps
    going, finishes the transcription and writes its conversation. The client
    sees a retryable error, retries, and each retry repeats the whole thing —
    four copies of one recording and four Soniox jobs, off a budget shared with
    the live streaming path (2026-08-15). Hence `paths_timeout`.
    """

    def __init__(self, app, methods_timeout: dict = None, paths_timeout: dict = None):
        super().__init__(app)

        self.default_timeout = self._get_timeout_from_env("HTTP_DEFAULT_TIMEOUT", default=2 * 60)

        self.methods_timeout = self._parse_methods_timeout(methods_timeout or {})
        self.paths_timeout = self._parse_paths_timeout(paths_timeout or {})

    @staticmethod
    def _get_timeout_from_env(env_var: str, default: float) -> float:
        timeout = os.environ.get(env_var, default)
        try:
            return float(timeout)
        except ValueError:
            raise ValueError(f"Invalid timeout value in env {env_var}: {timeout}")

    @staticmethod
    def _parse_methods_timeout(methods_timeout: dict) -> dict:
        result = {}
        for method, timeout in methods_timeout.items():
            if timeout is None:
                continue
            try:
                result[method.upper()] = float(timeout)
            except ValueError:
                raise ValueError(f"Invalid timeout value for method {method}: {timeout}")
        return result

    @staticmethod
    def _parse_paths_timeout(paths_timeout: dict) -> dict:
        result = {}
        for path, timeout in paths_timeout.items():
            if timeout is None:
                continue
            try:
                result[path] = float(timeout)
            except ValueError:
                raise ValueError(f"Invalid timeout value for path {path}: {timeout}")
        return result

    def _timeout_for(self, request: Request) -> float:
        """Path override wins over method override, which wins over the default.

        Matched by prefix so a trailing slash or a sub-path cannot silently drop
        back to the default — being off by one character here reintroduces the
        exact bug this parameter exists to fix, and does it silently.
        """
        path = request.url.path
        for prefix, timeout in self.paths_timeout.items():
            if path.startswith(prefix):
                return timeout
        return self.methods_timeout.get(request.method, self.default_timeout)

    async def dispatch(self, request: Request, call_next):
        timeout = self._timeout_for(request)
        try:
            return await asyncio.wait_for(call_next(request), timeout=timeout)
        except asyncio.TimeoutError:
            return Response(status_code=504)
