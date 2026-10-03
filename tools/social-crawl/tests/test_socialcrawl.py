"""Tests for the social-crawl plugin. Run: python3 -m unittest discover -s tests -v"""
from __future__ import annotations

import io
import json
import re
import socket
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "social-crawl" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from credentials import is_usable_key, parse_env, resolve_api_key  # noqa: E402
from socialcrawl import (  # noqa: E402
    UsageError, api_request, build_request, compact_endpoints, fetch_pages, main, normalize_path, parse_params,
)


def envelope(**extra):
    base = {"success": True, "endpoint": "/v1/x", "data": {"items": []}, "credits_used": 1,
            "credits_remaining": 9, "request_id": "r"}
    base.update(extra)
    return base


RETRYABLE = {"success": False, "error": {"type": "RATE_LIMITED", "retryable": True}, "credits_used": 0}


class FakeTransport:
    """Replays queued (status, headers, body) responses and records requests."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, url, method, headers, body, timeout):
        self.calls.append({"url": url, "method": method, "headers": headers, "body": body, "timeout": timeout})
        nxt = self.responses.pop(0)
        if isinstance(nxt, BaseException):
            raise nxt
        status, headers_out, payload = nxt if isinstance(nxt, tuple) else (200, {}, nxt)
        raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        return status, headers_out, raw

    def query(self, index=0):
        return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.calls[index]["url"]).query))


class Sandbox:
    def __init__(self, env_file=None, key_file=None):
        self._dir = tempfile.TemporaryDirectory()
        base = Path(self._dir.name)
        self.plugin_root = base / "plugin"
        self.home = base / "home"
        self.plugin_root.mkdir()
        (self.home / ".config" / "socialcrawl").mkdir(parents=True)
        if env_file is not None:
            (self.plugin_root / ".env").write_text(env_file)
        if key_file is not None:
            (self.home / ".config" / "socialcrawl" / "api_key").write_text(key_file)

    def kwargs(self):
        return {"plugin_root": self.plugin_root, "home": self.home}

    def cleanup(self):
        self._dir.cleanup()


class PackagingTests(unittest.TestCase):
    def test_manifest_is_agent_plugins_1_0(self):
        manifest = json.loads((ROOT / "plugin.json").read_text())
        allowed = {"$schema", "name", "version", "description", "author", "homepage", "repository",
                   "license", "keywords", "extensions"}
        self.assertEqual(manifest["$schema"], "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")
        self.assertRegex(manifest["name"], r"^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")
        self.assertEqual(set(manifest) - allowed, set())

    def test_no_mcp_server_or_javascript(self):
        self.assertFalse((ROOT / "mcp.json").exists())
        self.assertFalse((ROOT / ".mcp.json").exists())
        self.assertEqual([p for p in ROOT.rglob("*") if p.suffix in (".js", ".mjs", ".ts")], [])

    def test_skill_frontmatter(self):
        text = (ROOT / "skills" / "social-crawl" / "SKILL.md").read_text()
        frontmatter = re.match(r"^---\n(.*?)\n---\n", text, re.S).group(1)
        self.assertRegex(frontmatter, r"(?m)^name: social-crawl$")
        description = re.search(r"(?m)^description: (.+)$", frontmatter).group(1)
        self.assertLessEqual(len(description), 1024)
        self.assertNotIn("socialcrawl_", text, "skill must not reference MCP tools")
        self.assertTrue((ROOT / "skills" / "social-crawl" / "references" / "research-workflows.md").exists())

    def test_instructions_rule_exists(self):
        rule = (ROOT / "com.github.copilot" / "rules" / "social-crawl.instructions.md").read_text()
        self.assertTrue(rule.startswith("---\n"))
        self.assertNotIn("MCP", rule)

    def test_credentials_are_gitignored_and_template_is_placeholder(self):
        self.assertRegex((ROOT / ".gitignore").read_text(), r"(?m)^\.env$")
        example = parse_env((ROOT / ".env.example").read_text())
        self.assertIn("SOCIALCRAWL_API_KEY", example)
        self.assertFalse(is_usable_key(example["SOCIALCRAWL_API_KEY"]))


class CredentialTests(unittest.TestCase):
    def test_parse_env(self):
        text = "# c\nexport A=1\nB=\"two words\"\nC='three'\nD=four # note\nE=\nbad line\nF=x=y\r\n"
        self.assertEqual(parse_env(text), {"A": "1", "B": "two words", "C": "three", "D": "four", "E": "", "F": "x=y"})

    def test_placeholders_rejected(self):
        for value in ("", "sc_", "sc_your_key_here", "YOUR_API_KEY", "<key>", "${SOCIALCRAWL_API_KEY}", "sc_a b", None):
            self.assertFalse(is_usable_key(value), value)
        self.assertTrue(is_usable_key("sc_live_abc123"))

    def test_resolution_order(self):
        box = Sandbox(env_file="SOCIALCRAWL_API_KEY=sc_from_env_file\n", key_file="sc_from_key_file\n")
        self.addCleanup(box.cleanup)
        self.assertEqual(resolve_api_key({"SOCIALCRAWL_API_KEY": "sc_from_env"}, **box.kwargs())["key"], "sc_from_env")
        self.assertEqual(resolve_api_key({}, **box.kwargs())["key"], "sc_from_env_file")
        self.assertEqual(resolve_api_key({"SOCIALCRAWL_API_KEY": "YOUR_API_KEY"}, **box.kwargs())["key"], "sc_from_env_file")

        fallback = Sandbox(env_file="SOCIALCRAWL_API_KEY=sc_your_key_here\n", key_file="sc_from_key_file\n")
        self.addCleanup(fallback.cleanup)
        self.assertEqual(resolve_api_key({}, **fallback.kwargs())["key"], "sc_from_key_file")

        empty = Sandbox()
        self.addCleanup(empty.cleanup)
        result = resolve_api_key({}, **empty.kwargs())
        self.assertIsNone(result["key"])
        self.assertEqual(len(result["checked"]), 3)


class ArgumentTests(unittest.TestCase):
    def test_normalize_path(self):
        self.assertEqual(normalize_path("tiktok/profile")[0], "/v1/tiktok/profile")
        self.assertEqual(normalize_path("/v1/reddit/search")[0], "/v1/reddit/search")
        self.assertEqual(normalize_path("web/jobs/job_9f3k")[0], "/v1/web/jobs/job_9f3k")
        self.assertEqual(normalize_path("reddit/search?query=a+b")[1], [("query", "a b")])
        for bad in ("https://evil.example/v1/x", "//evil.example/x", "mailto:x", "reddit/../credits",
                    "reddit//search", "", "a/b#c", "a b/c"):
            with self.assertRaises(UsageError, msg=bad):
                normalize_path(bad)

    def test_parse_params(self):
        self.assertEqual(parse_params(["a=1", "a=2", "q=x=y"]), [("a", "1"), ("a", "2"), ("q", "x=y")])
        for pairs, initial in ((["api_key=sc_x"], None), ([], [("token", "1")]), (["novalue"], None)):
            with self.assertRaises(UsageError):
                parse_params(pairs, initial)

    def test_commands_map_to_endpoints(self):
        cases = [
            (["balance"], "/v1/credits/balance", {}),
            (["endpoints", "--search", "comments", "--platform", "youtube"], "/v1/utility/endpoints",
             {"search": "comments", "platform": "youtube"}),
            (["endpoint", "tiktok/profile"], "/v1/utility/endpoint", {"id": "tiktok/profile"}),
            (["endpoint", "/v1/tiktok/profile"], "/v1/utility/endpoint", {"url": "/v1/tiktok/profile"}),
            (["plan", "brand", "monitoring"], "/v1/utility/plan", {"query": "brand monitoring"}),
            (["search", "forums", "rivian r2", "timeframe=month"], "/v1/search/forums",
             {"query": "rivian r2", "timeframe": "month"}),
            (["web-search", "ai act", "limit=10"], "/v1/web/search", {"query": "ai act", "limit": "10"}),
            (["scrape", "https://example.com"], "/v1/web/scrape", {"url": "https://example.com"}),
            (["call", "reddit/search", "query=x", "trim=true", "--pages", "3"], "/v1/reddit/search",
             {"query": "x", "trim": "true"}),
        ]
        for argv, path, params in cases:
            request = build_request(argv)
            self.assertEqual(request["path"], path, argv)
            self.assertEqual(dict(request["params"]), params, argv)
        self.assertEqual(build_request(["call", "x/y", "--pages", "3"])["pages"], 3)
        self.assertTrue(build_request(["endpoints"])["compact"])
        self.assertFalse(build_request(["endpoints", "--full"])["compact"])

        post = build_request(["call", "web/batch-scrape", "--method", "post", "--body", '{"urls":["https://a.test"]}',
                              "--idempotency-key", "k1"])
        self.assertEqual((post["method"], post["body"], post["idempotency_key"]), ("POST", {"urls": ["https://a.test"]}, "k1"))
        self.assertIn("help", build_request(["--help"]))

    def test_invalid_input(self):
        for argv in (["unknown"], ["search", "bogus", "q"], ["search", "forums"], ["scrape", "example.com"],
                     ["call"], ["call", "x/y", "--pages", "0"], ["call", "x/y", "--pages", "21"],
                     ["call", "x/y", "--body", "{}"], ["call", "x/y", "--method", "PUT"],
                     ["call", "x/y", "--method", "POST", "--body", "not json"],
                     ["call", "x/y", "--method", "POST", "--pages", "2"], ["balance", "--timeout", "1"],
                     ["endpoint"], ["plan"], ["web-search", " "]):
            with self.assertRaises(UsageError, msg=argv):
                build_request(argv)


class HttpTests(unittest.TestCase):
    def test_key_only_in_header(self):
        transport = FakeTransport(envelope())
        result = api_request("sc_secret", "/v1/reddit/search", [("query", "a b")], transport=transport)
        self.assertTrue(result["success"])
        call = transport.calls[0]
        self.assertTrue(call["url"].startswith("https://www.socialcrawl.dev/v1/reddit/search?"))
        self.assertEqual(transport.query(), {"query": "a b"})
        self.assertNotIn("sc_secret", call["url"])
        self.assertEqual(call["headers"]["x-api-key"], "sc_secret")

    def test_retries_get_with_retry_after(self):
        waits = []
        transport = FakeTransport((429, {"Retry-After": "3"}, RETRYABLE), envelope())
        result = api_request("sc_k", "/v1/x", transport=transport, sleep=waits.append)
        self.assertTrue(result["success"])
        self.assertEqual(waits, [3.0])

    def test_retry_budget(self):
        transport = FakeTransport(RETRYABLE, RETRYABLE, RETRYABLE)
        self.assertFalse(api_request("sc_k", "/v1/x", transport=transport, sleep=lambda s: None)["success"])
        self.assertEqual(len(transport.calls), 3)

    def test_writes_retry_only_with_idempotency_key(self):
        once = FakeTransport(RETRYABLE, envelope())
        self.assertFalse(api_request("sc_k", "/v1/x", method="POST", body={}, transport=once, sleep=lambda s: None)["success"])
        self.assertEqual(len(once.calls), 1)

        keyed = FakeTransport(RETRYABLE, envelope())
        result = api_request("sc_k", "/v1/x", method="POST", body={"a": 1}, idempotency_key="job-1",
                             transport=keyed, sleep=lambda s: None)
        self.assertTrue(result["success"])
        self.assertEqual(keyed.calls[0]["headers"]["Idempotency-Key"], "job-1")
        self.assertEqual(keyed.calls[0]["body"], b'{"a": 1}')

    def test_non_json_and_network_errors(self):
        with self.assertRaisesRegex(RuntimeError, r"Non-JSON response \(HTTP 502\)"):
            api_request("sc_k", "/v1/x", transport=FakeTransport((502, {}, b"<html>")))
        with self.assertRaisesRegex(RuntimeError, "timed out after 5s"):
            api_request("sc_k", "/v1/x", timeout=5, transport=FakeTransport(socket.timeout("t")))
        with self.assertRaisesRegex(RuntimeError, "Network error"):
            api_request("sc_k", "/v1/x", transport=FakeTransport(ConnectionError("refused")))

    def test_pagination(self):
        def page(item, cursor, more):
            return envelope(data={"items": [item]}, pagination={"next_cursor": cursor, "has_more": more},
                            request_id=f"r{item}")

        transport = FakeTransport(page(1, "c1", True), page(2, "c2", True), page(3, None, False))
        result = fetch_pages("sc_k", "/v1/x", [("q", "a")], pages=5, transport=transport)
        self.assertEqual(result["data"]["items"], [1, 2, 3])
        self.assertEqual((result["pages_fetched"], result["credits_used"]), (3, 3))
        self.assertEqual([transport.query(i).get("cursor") for i in range(3)], [None, "c1", "c2"])
        self.assertTrue(all(transport.query(i)["q"] == "a" for i in range(3)))

        limited = FakeTransport(page(1, "c1", True), page(2, "c2", True))
        two = fetch_pages("sc_k", "/v1/x", pages=2, transport=limited)
        self.assertEqual(two["pages_fetched"], 2)
        self.assertTrue(two["pagination"]["has_more"])

    def test_partial_pagination_failure(self):
        transport = FakeTransport(
            envelope(data={"items": [1]}, pagination={"next_cursor": "c1", "has_more": True}),
            {"success": False, "error": {"type": "INSUFFICIENT_CREDITS", "retryable": False}, "credits_used": 0,
             "credits_remaining": 0},
        )
        result = fetch_pages("sc_k", "/v1/x", pages=3, transport=transport)
        self.assertFalse(result["success"])
        self.assertTrue(result["partial"])
        self.assertEqual(result["data"]["items"], [1])
        self.assertEqual(result["error"]["type"], "INSUFFICIENT_CREDITS")

    def test_compact_endpoints(self):
        compact = compact_endpoints({"success": True, "data": {"total": 1, "endpoints": [
            {"id": "a/b", "method": "GET", "credits": 1, "summary": "s", "required_params": ["q"], "one_of": [],
             "credits_label": "long", "docs_url": "u"}]}})
        self.assertEqual(compact["data"]["endpoints"],
                         [{"id": "a/b", "method": "GET", "credits": 1, "summary": "s", "required_params": ["q"]}])


class MainTests(unittest.TestCase):
    def run_main(self, argv, box, transport=None):
        out, err = io.StringIO(), io.StringIO()
        kwargs = {"env": {}, "stdout": out, "stderr": err, **box.kwargs()}
        if transport:
            kwargs["transport"] = transport
        return main(argv, **kwargs), out.getvalue(), err.getvalue()

    def test_missing_key(self):
        box = Sandbox()
        self.addCleanup(box.cleanup)
        code, out, err = self.run_main(["balance"], box)
        self.assertEqual(code, 1)
        self.assertIn("No SocialCrawl API key found", err)
        self.assertEqual(out, "")

    def test_api_error_and_output_file(self):
        box = Sandbox(env_file="SOCIALCRAWL_API_KEY=sc_test_key\n")
        self.addCleanup(box.cleanup)
        failure = FakeTransport((400, {}, {"success": False, "credits_used": 0,
                                           "error": {"type": "INVALID_REQUEST", "message": "query is required"}}))
        code, out, err = self.run_main(["call", "reddit/search"], box, failure)
        self.assertEqual(code, 2)
        self.assertIn("INVALID_REQUEST: query is required", err)
        self.assertNotIn("sc_test_key", out + err)

        file = box.plugin_root / "out" / "result.json"
        code, out, _ = self.run_main(["call", "reddit/search", "query=x", "--output", str(file)], box,
                                     FakeTransport(envelope(data={"items": [1, 2]})))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(file.read_text())["data"]["items"], [1, 2])
        self.assertEqual(json.loads(out)["items"], 2)

    def test_key_redacted_from_errors(self):
        box = Sandbox(env_file="SOCIALCRAWL_API_KEY=sc_leaky_key\n")
        self.addCleanup(box.cleanup)
        code, out, err = self.run_main(["balance"], box, FakeTransport(ValueError("failed with sc_leaky_key")))
        self.assertEqual(code, 1)
        self.assertNotIn("sc_leaky_key", out + err)

    def test_usage_errors_exit_1(self):
        box = Sandbox()
        self.addCleanup(box.cleanup)
        code, _, err = self.run_main(["call", "https://evil.test/x"], box)
        self.assertEqual(code, 1)
        self.assertIn("not a full URL", err)


if __name__ == "__main__":
    unittest.main()
