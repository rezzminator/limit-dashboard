import base64
import importlib.util
import json
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "claude_usage_fetch.py"
SPEC = importlib.util.spec_from_file_location("claude_usage_fetch", SCRIPT)
assert SPEC and SPEC.loader
FETCH = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = FETCH
SPEC.loader.exec_module(FETCH)


class FakeResponse:
    def __init__(self, status, content=b"", headers=None):
        self.status_code = status
        self.content = content
        self.headers = headers or {}


class FakeSession:
    def __init__(self, responses, calls, **kwargs):
        self.responses = iter(responses)
        self.calls = calls
        self.session_kwargs = kwargs

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs, self.session_kwargs))
        return next(self.responses)


class ClaudeUsageFetchTests(unittest.TestCase):
    def factory(self, responses, calls):
        return lambda **kwargs: FakeSession(responses, calls, **kwargs)

    def test_uses_chrome_impersonation_and_bearer_header(self):
        calls = []
        body = b'{"five_hour":{"utilization":12}}'
        result = FETCH.fetch_usage(
            "secret-token",
            self.factory([FakeResponse(200, body)], calls),
        )

        self.assertEqual(result, FETCH.FetchResult(status=200, body=body))
        self.assertEqual(len(calls), 1)
        url, kwargs, _ = calls[0]
        self.assertEqual(url, FETCH.USAGE_URL)
        self.assertEqual(kwargs["impersonate"], "chrome")
        self.assertEqual(
            kwargs["headers"]["Authorization"],
            "Bearer secret-token",
        )
        self.assertFalse(kwargs["allow_redirects"])

    def test_redirects_are_manual_and_limited_to_claude_https(self):
        calls = []
        result = FETCH.fetch_usage(
            "token",
            self.factory(
                [
                    FakeResponse(302, headers={"location": "/api/oauth/usage?v=2"}),
                    FakeResponse(200, b"{}"),
                ],
                calls,
            ),
        )
        self.assertEqual(result.status, 200)
        self.assertEqual(len(calls), 2)
        self.assertEqual(
            calls[1][0],
            "https://claude.ai/api/oauth/usage?v=2",
        )

        with self.assertRaisesRegex(FETCH.FetchError, "redirect_refused"):
            FETCH.fetch_usage(
                "token",
                self.factory(
                    [
                        FakeResponse(
                            302,
                            headers={"location": "https://example.com/steal"},
                        )
                    ],
                    [],
                ),
            )

    def test_output_envelope_carries_body_without_token(self):
        body = b'{"seven_day":{"utilization":42}}'
        encoded = base64.b64encode(body).decode("ascii")
        envelope = {
            "schema_version": 1,
            "status": 200,
            "body_base64": encoded,
            "error": None,
        }
        rendered = json.dumps(envelope)
        self.assertIn(encoded, rendered)
        self.assertNotIn("access_token", rendered)


if __name__ == "__main__":
    unittest.main()
