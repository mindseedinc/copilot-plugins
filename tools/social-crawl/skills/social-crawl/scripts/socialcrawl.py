#!/usr/bin/env python3
"""SocialCrawl CLI for agents (https://www.socialcrawl.dev). Python 3.9+, stdlib only.

Free discovery (0 credits):
  balance                                   Verify the key and show the credit balance
  endpoints [--search TEXT] [--platform P]  Search the live endpoint catalogue (--full for raw)
  endpoint <id-or-path> [--method M]        Parameters, cost, and paging for one endpoint
  plan "<job in plain words>"               Ordered calls, parameters, and prices for a job
  capabilities [--param NAME]               Cross-endpoint parameters (label, relevance, trim, ...)
  llms [--platform P] [--format json]       Agent context for the API or one platform

Billed calls (check cost first):
  call <path> [key=value ...]               Any endpoint, e.g. call tiktok/profile handle=nasa
  search <lane> "<query>" [key=value ...]   Lanes: everywhere, forums, creators, news, multi
  web-search "<query>" [key=value ...]      Web, news, and image results (/v1/web/search)
  scrape <url> [key=value ...]              One page as clean markdown (/v1/web/scrape)

Options (after the command):
  --pages N              Follow pagination cursors up to N pages (default 1, max 20)
  --method M             HTTP method for call: GET (default), POST, PATCH, DELETE
  --body JSON|@file      JSON body for POST/PATCH (batch, crawl, monitors)
  --idempotency-key K    Idempotency-Key header for POST batch or job submissions
  --output FILE          Write the full JSON response to FILE; print a summary instead
  --timeout SECONDS      Per-request timeout (default 120)

Exit codes: 0 success, 1 usage/configuration/network error, 2 API error envelope.
"""
from __future__ import annotations

import argparse
import json
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from credentials import resolve_api_key  # noqa: E402

BASE_URL = "https://www.socialcrawl.dev"
SEARCH_LANES = ("everywhere", "forums", "creators", "news", "multi")
METHODS = ("GET", "POST", "PATCH", "DELETE")
FORBIDDEN_PARAMS = {"api_key", "apikey", "x-api-key", "key", "token"}
USER_AGENT = "social-crawl-agent-plugin/0.2.0"

Params = List[Tuple[str, str]]
# transport(url, method, headers, body_bytes, timeout) -> (status, headers, body_bytes)
Transport = Callable[[str, str, Dict[str, str], Optional[bytes], float], Tuple[int, Dict[str, str], bytes]]


class UsageError(Exception):
    """Invalid command-line input."""


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        raise UsageError(message)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # urllib copies custom headers (including x-api-key) onto redirects; refuse them.
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        raise urllib.error.HTTPError(req.full_url, code, f"Refusing redirect to {newurl}", headers, fp)


_OPENER = urllib.request.build_opener(_NoRedirect)


def urllib_transport(url: str, method: str, headers: Dict[str, str], body: Optional[bytes], timeout: float):
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return response.status, dict(response.headers.items()), response.read()
    except urllib.error.HTTPError as error:
        if 300 <= error.code < 400:
            raise ConnectionError(f"unexpected redirect (HTTP {error.code})") from None
        return error.code, dict(error.headers.items()) if error.headers else {}, error.read() or b""


def normalize_path(value: str) -> Tuple[str, Params]:
    """Turn 'tiktok/profile', '/v1/tiktok/profile', or 'x/y?a=b' into ('/v1/x/y', [('a','b')])."""
    if not isinstance(value, str) or not value.strip():
        raise UsageError("An API path is required, for example tiktok/profile.")
    path = value.strip()
    if path.startswith("//") or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", path):
        raise UsageError("Pass a SocialCrawl API path such as tiktok/profile, not a full URL.")
    path, _, query = path.partition("?")
    path = path.lstrip("/")
    if path.startswith("v1/"):
        path = path[3:]
    segments = path.split("/")
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.~%-")
    if not path or "#" in value or any(s in ("", ".", "..") or not set(s) <= allowed for s in segments):
        raise UsageError(f'Invalid API path "{value}". Use a catalogue path such as reddit/search.')
    return f"/v1/{path}", urllib.parse.parse_qsl(query, keep_blank_values=True)


def parse_params(pairs: Sequence[str], initial: Optional[Params] = None) -> Params:
    params: Params = list(initial or [])
    for pair in pairs:
        key, sep, val = pair.partition("=")
        if not sep or not key.strip():
            raise UsageError(f'Expected key=value, got "{pair}".')
        params.append((key.strip(), val))
    for key, _ in params:
        if key.lower() in FORBIDDEN_PARAMS:
            raise UsageError(f'Do not pass credentials as "{key}". The key is sent only in the x-api-key header.')
    return params


def _retry_delay(headers: Dict[str, str], attempt: int) -> float:
    raw = next((v for k, v in headers.items() if k.lower() == "retry-after"), None)
    try:
        seconds = float(raw) if raw is not None else 2.0 ** attempt
    except ValueError:
        seconds = 2.0 ** attempt
    return min(max(seconds, 0.0), 30.0)


def api_request(
    api_key: str,
    path: str,
    params: Optional[Params] = None,
    method: str = "GET",
    body: Any = None,
    idempotency_key: Optional[str] = None,
    timeout: float = 120.0,
    base_url: str = BASE_URL,
    transport: Transport = urllib_transport,
    retries: int = 2,
    sleep: Callable[[float], None] = time.sleep,
) -> Dict[str, Any]:
    """Send one request and return the JSON envelope.

    Retries only failures the API marks retryable, and only when repeating is safe
    (GET, or a write carrying an Idempotency-Key).
    """
    if not api_key:
        raise RuntimeError("No API key available.")
    url = base_url + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"x-api-key": api_key, "Accept": "application/json", "User-Agent": USER_AGENT}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    repeatable = method == "GET" or bool(idempotency_key)

    attempt = 0
    while True:
        try:
            status, response_headers, raw = transport(url, method, headers, data, timeout)
        except (urllib.error.URLError, ConnectionError, OSError) as error:
            reason = getattr(error, "reason", None) or error
            if isinstance(error, (socket.timeout, TimeoutError)) or isinstance(reason, (socket.timeout, TimeoutError)):
                raise RuntimeError(f"Request timed out after {timeout:g}s: {method} {path}") from None
            raise RuntimeError(f"Network error calling {method} {path}: {reason}") from None
        try:
            envelope = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise RuntimeError(f"Non-JSON response (HTTP {status}) from {method} {path}.") from None
        error = envelope.get("error") if isinstance(envelope, dict) else None
        if (
            isinstance(envelope, dict) and envelope.get("success") is False
            and isinstance(error, dict) and error.get("retryable") is True
            and repeatable and attempt < retries
        ):
            sleep(_retry_delay(response_headers, attempt))
            attempt += 1
            continue
        return envelope


def fetch_pages(api_key: str, path: str, params: Optional[Params] = None, pages: int = 1, **options: Any) -> Dict[str, Any]:
    """Follow pagination.next_cursor as ?cursor= until has_more is false or `pages` is reached."""
    params = list(params or [])
    first = api_request(api_key, path, params, **options)
    if pages <= 1 or first.get("success") is not True or not first.get("pagination"):
        return first

    envelopes = [first]
    current = first
    failure = None
    while len(envelopes) < pages:
        pagination = current.get("pagination") or {}
        if pagination.get("has_more") is not True or not pagination.get("next_cursor"):
            break
        next_params = [(k, v) for k, v in params if k != "cursor"] + [("cursor", pagination["next_cursor"])]
        page = api_request(api_key, path, next_params, **options)
        if page.get("success") is not True:
            failure = page
            break
        envelopes.append(page)
        current = page

    items: List[Any] = []
    for page in envelopes:
        page_items = (page.get("data") or {}).get("items")
        if isinstance(page_items, list):
            items.extend(page_items)
    result: Dict[str, Any] = {"success": failure is None}
    if failure is not None:
        result.update(partial=True, error=failure.get("error"), failed_request_id=failure.get("request_id"))
    result.update(
        platform=first.get("platform"),
        endpoint=first.get("endpoint"),
        pages_fetched=len(envelopes),
        data={**(first.get("data") or {}), "items": items},
        pagination=current.get("pagination"),
        credits_used=sum(_number(p.get("credits_used")) for p in envelopes) + _number((failure or {}).get("credits_used")),
        credits_remaining=(failure or current).get("credits_remaining", current.get("credits_remaining")),
        request_ids=[p.get("request_id") for p in envelopes],
    )
    return result


def _number(value: Any) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0
    return int(number) if number.is_integer() else number


def compact_endpoints(envelope: Dict[str, Any]) -> Dict[str, Any]:
    """Shrink the endpoint catalogue to the fields an agent needs to choose a call."""
    data = envelope.get("data") if isinstance(envelope, dict) else None
    endpoints = data.get("endpoints") if isinstance(data, dict) else None
    if envelope.get("success") is not True or not isinstance(endpoints, list):
        return envelope
    keep = ("id", "method", "credits", "metered", "paginated", "summary", "required_params", "one_of")
    return {
        **envelope,
        "data": {
            "total": data.get("total", len(endpoints)),
            "filters": data.get("filters"),
            "note": 'Compact view. Run "endpoint <id>" for parameters and pricing, or add --full.',
            "endpoints": [{k: e.get(k) for k in keep if e.get(k) not in (None, [])} for e in endpoints],
        },
    }


def _positive_int(name: str, low: int, high: int) -> Callable[[str], int]:
    def parse(value: str) -> int:
        if not value.isdigit() or not low <= int(value) <= high:
            raise argparse.ArgumentTypeError(f"{name} must be an integer between {low} and {high}")
        return int(value)
    return parse


def _build_parser() -> ArgumentParser:
    common = ArgumentParser(add_help=False)
    common.add_argument("--pages", type=_positive_int("--pages", 1, 20), default=1)
    common.add_argument("--output")
    common.add_argument("--timeout", type=_positive_int("--timeout", 5, 900), default=120)

    parser = ArgumentParser(prog="socialcrawl.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")

    def add(name: str, **kwargs: Any) -> ArgumentParser:
        return sub.add_parser(name, parents=[common], **kwargs)

    add("balance").add_argument("params", nargs="*")
    p = add("endpoints")
    p.add_argument("--search")
    p.add_argument("--platform")
    p.add_argument("--method")
    p.add_argument("--full", action="store_true")
    p.add_argument("params", nargs="*")
    p = add("endpoint")
    p.add_argument("target")
    p.add_argument("--method")
    p.add_argument("params", nargs="*")
    add("plan").add_argument("job", nargs="+")
    p = add("capabilities")
    p.add_argument("--param")
    p.add_argument("params", nargs="*")
    p = add("llms")
    p.add_argument("--platform")
    p.add_argument("--format", choices=("markdown", "json"))
    p.add_argument("params", nargs="*")
    p = add("call")
    p.add_argument("path")
    p.add_argument("params", nargs="*")
    p.add_argument("--method", type=str.upper, choices=METHODS, default="GET")
    p.add_argument("--body")
    p.add_argument("--idempotency-key")
    p = add("search")
    p.add_argument("lane", choices=SEARCH_LANES)
    p.add_argument("query")
    p.add_argument("params", nargs="*")
    p = add("web-search")
    p.add_argument("query")
    p.add_argument("params", nargs="*")
    p = add("scrape")
    p.add_argument("url")
    p.add_argument("params", nargs="*")
    return parser


def _read_body(value: Optional[str]) -> Any:
    if value is None:
        return None
    text = Path(value[1:]).expanduser().read_text(encoding="utf-8") if value.startswith("@") else value
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise UsageError("--body must be valid JSON or @path/to/file.json.") from None


def _text(value: str, message: str) -> str:
    if not value or not value.strip():
        raise UsageError(message)
    return value.strip()


def build_request(argv: Sequence[str]) -> Dict[str, Any]:
    """Convert CLI arguments into a request description without performing I/O."""
    parser = _build_parser()
    if not argv or argv[0] in ("-h", "--help", "help"):
        return {"help": parser.format_help()}
    args = parser.parse_args(list(argv))
    request: Dict[str, Any] = {
        "method": "GET", "pages": args.pages, "timeout": float(args.timeout),
        "output": args.output, "body": None, "idempotency_key": None, "compact": False,
    }

    def optional(*pairs: Tuple[str, Optional[str]]) -> Params:
        return [(k, v) for k, v in pairs if v is not None]

    extra = getattr(args, "params", []) or []
    command = args.command
    if command == "balance":
        request.update(path="/v1/credits/balance", params=parse_params(extra))
    elif command == "endpoints":
        request.update(path="/v1/utility/endpoints", compact=not args.full, params=parse_params(
            extra, optional(("search", args.search), ("platform", args.platform), ("method", args.method))))
    elif command == "endpoint":
        target = _text(args.target, "endpoint needs an id (tiktok/profile) or path (/v1/tiktok/profile).")
        key = "url" if target.startswith("/") else "id"
        request.update(path="/v1/utility/endpoint", params=parse_params(
            extra, optional((key, target), ("method", args.method.upper() if args.method else None))))
    elif command == "plan":
        request.update(path="/v1/utility/plan", params=[("query", _text(" ".join(args.job), "plan needs a job description."))])
    elif command == "capabilities":
        request.update(path="/v1/utility/capabilities", params=parse_params(extra, optional(("param", args.param))))
    elif command == "llms":
        request.update(path="/v1/utility/llms", params=parse_params(
            extra, optional(("platform", args.platform), ("format", args.format))))
    elif command == "call":
        path, query = normalize_path(args.path)
        body = _read_body(args.body)
        if body is not None and args.method in ("GET", "DELETE"):
            raise UsageError("--body requires --method POST or PATCH.")
        if args.method != "GET" and args.pages > 1:
            raise UsageError("--pages applies only to GET requests.")
        request.update(path=path, method=args.method, body=body, idempotency_key=args.idempotency_key,
                       params=parse_params(extra, query))
    elif command == "search":
        query = _text(args.query, "search needs a quoted query.")
        request.update(path=f"/v1/search/{args.lane}", params=parse_params(extra, [("query", query)]))
    elif command == "web-search":
        query = _text(args.query, "web-search needs a quoted query.")
        request.update(path="/v1/web/search", params=parse_params(extra, [("query", query)]))
    elif command == "scrape":
        url = _text(args.url, "scrape needs a URL.")
        if not url.lower().startswith(("http://", "https://")):
            raise UsageError("scrape needs an absolute http(s) URL.")
        request.update(path="/v1/web/scrape", params=parse_params(extra, [("url", url)]))
    else:
        return {"help": parser.format_help()}
    return request


def _summary(result: Dict[str, Any], file: Path) -> Dict[str, Any]:
    data = result.get("data") if isinstance(result, dict) else None
    listing = None
    if isinstance(data, dict):
        listing = data.get("items") if isinstance(data.get("items"), list) else data.get("endpoints")
    summary = {
        "saved_to": str(file),
        "success": result.get("success"),
        "endpoint": result.get("endpoint"),
        "items": len(listing) if isinstance(listing, list) else None,
        "pages_fetched": result.get("pages_fetched"),
        "pagination": result.get("pagination"),
        "credits_used": result.get("credits_used"),
        "credits_remaining": result.get("credits_remaining"),
        "error": result.get("error"),
    }
    return {k: v for k, v in summary.items() if v is not None}


def main(
    argv: Optional[Sequence[str]] = None,
    env: Optional[Dict[str, str]] = None,
    stdout=None,
    stderr=None,
    plugin_root: Optional[Path] = None,
    home: Optional[Path] = None,
    transport: Transport = urllib_transport,
) -> int:
    stdout = stdout or sys.stdout
    stderr = stderr or sys.stderr
    try:
        request = build_request(sys.argv[1:] if argv is None else argv)
    except (UsageError, OSError) as error:
        stderr.write(f"socialcrawl: {error}\n")
        return 1
    if "help" in request:
        stdout.write(request["help"])
        return 0

    resolved = resolve_api_key(env=env, plugin_root=plugin_root, home=home)
    key = resolved["key"]
    if not key:
        stderr.write(
            "socialcrawl: No SocialCrawl API key found. Checked: " + ", ".join(resolved["checked"]) + ".\n"
            "Create a key at https://www.socialcrawl.dev/dashboard and add SOCIALCRAWL_API_KEY=sc_... "
            "to the plugin .env file.\n"
        )
        return 1

    try:
        result = fetch_pages(
            key, request["path"], request["params"], pages=request["pages"], method=request["method"],
            body=request["body"], idempotency_key=request["idempotency_key"], timeout=request["timeout"],
            transport=transport,
        )
        if request["compact"]:
            result = compact_endpoints(result)
        if request["output"]:
            file = Path(request["output"]).expanduser().resolve()
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            stdout.write(json.dumps(_summary(result, file), indent=2, ensure_ascii=False) + "\n")
        else:
            stdout.write(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    except Exception as error:  # noqa: BLE001 - report any failure without a traceback or the key
        stderr.write(f"socialcrawl: {str(error).replace(key, '[redacted]')}\n")
        return 1

    if not isinstance(result, dict) or result.get("success") is not True:
        err = (result or {}).get("error") or {}
        doc = f" ({err['doc_url']})" if err.get("doc_url") else ""
        stderr.write(f"socialcrawl: {err.get('type', 'API_ERROR')}: {err.get('message', 'Request failed.')}{doc}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
