#!/usr/bin/env python3
"""Fetch Claude quota with the curl_cffi transport used by harvester-web-mcp.

The access token is accepted only as JSON on stdin. It is never placed in the
process arguments, environment, logs, or output. The destination is fixed so
this helper cannot be repurposed as an authenticated general-purpose fetcher.
"""

from __future__ import annotations

import base64
import json
import sys
from dataclasses import dataclass
from typing import Any, Callable
from urllib.parse import urljoin, urlparse


USAGE_URL = "https://claude.ai/api/oauth/usage"
REDIRECT_CODES = {301, 302, 303, 307, 308}
MAX_REDIRECTS = 3
MAX_RESPONSE_BYTES = 32 * 1024


class FetchError(RuntimeError):
    """A credential-free failure safe to return to the dashboard."""


@dataclass(frozen=True)
class FetchResult:
    status: int
    body: bytes


def _session_kwargs() -> dict[str, Any]:
    """Lock libcurl to HTTP(S), matching harvester's defense in depth."""
    try:
        from curl_cffi import CurlOpt
    except ImportError:
        return {}
    return {
        "curl_options": {
            CurlOpt.PROTOCOLS_STR: "https,http",
            CurlOpt.REDIR_PROTOCOLS_STR: "https,http",
        }
    }


def _allowed_url(url: str) -> bool:
    parsed = urlparse(url)
    return (
        parsed.scheme == "https"
        and parsed.hostname == "claude.ai"
        and parsed.username is None
        and parsed.password is None
    )


def fetch_usage(
    access_token: str,
    session_factory: Callable[..., Any] | None = None,
) -> FetchResult:
    if not access_token:
        raise FetchError("missing_access_token")

    if session_factory is None:
        try:
            from curl_cffi.requests import Session
        except ImportError as error:
            raise FetchError("curl_cffi_unavailable") from error
        session_factory = Session

    current = USAGE_URL
    try:
        with session_factory(**_session_kwargs()) as session:
            for _ in range(MAX_REDIRECTS + 1):
                if not _allowed_url(current):
                    raise FetchError("redirect_refused")
                response = session.get(
                    current,
                    impersonate="chrome",
                    headers={
                        "Authorization": f"Bearer {access_token}",
                        "Accept": "application/json",
                        "Content-Type": "application/json",
                    },
                    timeout=25,
                    allow_redirects=False,
                )
                location = response.headers.get("location")
                if response.status_code in REDIRECT_CODES and location:
                    current = urljoin(current, location)
                    continue

                body = bytes(response.content)
                if len(body) > MAX_RESPONSE_BYTES:
                    raise FetchError("response_too_large")
                return FetchResult(status=int(response.status_code), body=body)
    except FetchError:
        raise
    except Exception as error:
        raise FetchError("transport_failed") from error

    raise FetchError("too_many_redirects")


def _emit(*, status: int | None, body: bytes = b"", error: str | None = None) -> None:
    print(
        json.dumps(
            {
                "schema_version": 1,
                "status": status,
                "body_base64": base64.b64encode(body).decode("ascii"),
                "error": error,
            },
            separators=(",", ":"),
        )
    )


def main() -> int:
    try:
        request = json.load(sys.stdin)
        access_token = request.get("access_token")
        if not isinstance(access_token, str):
            raise FetchError("invalid_input")
        result = fetch_usage(access_token)
    except (FetchError, json.JSONDecodeError) as error:
        code = str(error) if isinstance(error, FetchError) else "invalid_input"
        _emit(status=None, error=code)
        return 2
    except Exception:
        _emit(status=None, error="helper_failed")
        return 2

    _emit(status=result.status, body=result.body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
