"""Access token authentication tests — parametrized across all branches.

Each branch gets a separate auth-enabled container (pool key: "{branch}:auth").
"""

from __future__ import annotations

import http.client
import re
import subprocess
import time
from urllib.parse import urljoin, urlsplit

import pytest
import requests as http_requests

from conftest import (
    ACCESS_TOKEN,
    attach_log,
    get_branch_params,
    get_or_start_container,
    resolve_and_check,
    save_screenshot,
)
from helpers.constants import PRIVILEGED_BRANCHES
from helpers.containers import container_labels

TOKEN_HEADER = "X-IDEKUBE-Container-Access-Token"
TOKEN_PARAM = "idekube-container-access-token"
TOKEN_COOKIE = "idekube_container_access_token"

# Values that must never authenticate against ACCESS_TOKEN.
NEAR_MISS_TOKENS = [
    pytest.param(ACCESS_TOKEN.lower(), id="lower-case"),
    pytest.param(ACCESS_TOKEN.swapcase(), id="swapped-case"),
    pytest.param(ACCESS_TOKEN.replace(".", "X"), id="dot-as-wildcard"),
    pytest.param(ACCESS_TOKEN[:-1], id="prefix"),
    pytest.param(ACCESS_TOKEN + "x", id="suffix"),
    # The template placeholders are public; neither may ever act as a token.
    pytest.param("__IDEKUBE_ACCESS_TOKEN_PLACEHOLDER__", id="old-public-placeholder"),
    pytest.param("__IDEKUBE_ACCESS_TOKEN_REGEX__", id="template-placeholder"),
]


def pytest_generate_tests(metafunc):
    if "branch" in metafunc.fixturenames:
        metafunc.parametrize("branch", get_branch_params(metafunc.config), indirect=False)


# TLS terminates at the ingress, so the in-container nginx only ever sees plain
# HTTP. Send the header the ingress would add to mirror that setup.
FORWARDED_HTTPS = {"X-Forwarded-Proto": "https"}

# Origin the browser is on when it follows a redirect from the workspace.
PAGE_URL = "https://ws.example.com/"

# Token-link paths that must not turn the post-login redirect into an off-site
# jump or a header injection. Sent byte-for-byte, without client normalization.
HOSTILE_PATHS = [
    "/%5cevil.example/",  # nginx decodes to "/\evil.example/" -> other host
    "/%5Cevil.example/",
    "/\\evil.example/",  # raw backslash
    "//evil.example/",  # raw protocol-relative path
    "/%2f%5cevil.example/",
    "/%09/evil.example/",  # browsers drop the tab -> "//evil.example/"
    "/%0d%0aX-Injected:%20yes",  # CRLF would split the Location header
]


def _browser_resolve(location: str) -> str:
    """Resolve a Location value the way a browser does for http(s) pages.

    Mirrors the WHATWG URL parser quirks that matter for redirects: ASCII
    tab/newline are removed anywhere, leading C0 controls and spaces are
    trimmed, and "\\" is treated like "/".
    """
    cleaned = re.sub(r"[\t\n\r]", "", location).lstrip("".join(map(chr, range(0x21))))
    return urljoin(PAGE_URL, cleaned.replace("\\", "/"))


def _assert_relative_location(location: str | None):
    """Redirects must be relative and must stay on the page's own origin.

    An absolute http:// Location gets blocked as mixed content for
    subresources (e.g. the favicon probe) and downgrades top-level navigations;
    a "//" or "/\\" prefix sends the browser to another host.
    """
    location = location or ""
    assert re.fullmatch(r"/(?![/\\])[\x21-\x7e]*", location), (
        f"Expected a relative, printable-ASCII Location header, got {location!r}"
    )
    resolved = urlsplit(_browser_resolve(location))
    assert (resolved.scheme, resolved.netloc) == ("https", urlsplit(PAGE_URL).netloc), (
        f"Location {location!r} resolves off-site to {_browser_resolve(location)!r}"
    )


def _raw_get(base_url: str, raw_target: str) -> http.client.HTTPResponse:
    """GET a request-target exactly as given (requests would re-encode it)."""
    parts = urlsplit(base_url)
    conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=10)
    try:
        conn.request("GET", raw_target, headers=FORWARDED_HTTPS)
        resp = conn.getresponse()
        resp.read()
        return resp
    finally:
        conn.close()


def _status_with_header(cm, token: str) -> int:
    return http_requests.get(
        f"{cm.base_url}/", headers={TOKEN_HEADER: token}, timeout=10, allow_redirects=False
    ).status_code


def _render_token(cm, token: str) -> None:
    """Re-run authn.sh in the container with ``token``, then reload nginx."""
    rendered = subprocess.run(
        ["docker", "exec", "-e", f"IDEKUBE_ACCESS_TOKEN={token}", cm.container_id, "bash", "/authn.sh"],
        capture_output=True, text=True, timeout=30,
    )
    assert rendered.returncode == 0, f"authn.sh failed: {rendered.stdout}{rendered.stderr}"
    reloaded = cm.exec_run(["nginx", "-s", "reload"])
    assert reloaded.returncode == 0, f"nginx reload failed: {reloaded.stderr}"
    # Reload is asynchronous: wait until the new token is the one accepted.
    deadline = time.monotonic() + 10
    while _status_with_header(cm, token) == 401 and time.monotonic() < deadline:
        time.sleep(0.2)


def _get_auth_container(branch, lineup, container_pool, output_dir):
    """Get or start an auth-enabled container for this branch."""
    image_ref = resolve_and_check(branch, lineup)
    return get_or_start_container(
        container_pool,
        branch,
        image_ref,
        output_dir,
        extra_env={"IDEKUBE_ACCESS_TOKEN": ACCESS_TOKEN},
        pool_key=f"{branch}:auth",
    )


class TestAccessTokenAuth:
    """Verify nginx-level access token authentication on every branch."""

    def test_unauthenticated_blocked(self, branch, container_pool, output_dir, lineup, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = http_requests.get(f"{cm.base_url}/", timeout=10, allow_redirects=False)
        assert resp.status_code == 401, f"Expected 401, got {resp.status_code}"

    def test_query_param_auth(self, branch, container_pool, output_dir, lineup, page, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        url = f"{cm.base_url}/?idekube-container-access-token={ACCESS_TOKEN}"
        resp = page.goto(url, wait_until="networkidle", timeout=30000)
        assert resp is not None
        assert resp.status != 401, "Query param auth should not return 401"
        assert resp.status < 500, f"Query param auth returned {resp.status}"
        save_screenshot(request.node, page, f"{branch.replace('/', '-')}_auth_query")

    def test_cookie_set_after_query_param(self, branch, container_pool, output_dir, lineup, page, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        url = f"{cm.base_url}/?idekube-container-access-token={ACCESS_TOKEN}"
        page.goto(url, wait_until="networkidle", timeout=30000)
        cookie_names = [c["name"] for c in page.context.cookies()]
        assert "idekube_container_access_token" in cookie_names, (
            f"Expected cookie 'idekube_container_access_token' in {cookie_names}"
        )

    def test_cookie_auth(self, branch, container_pool, output_dir, lineup, page, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        page.context.add_cookies([{
            "name": "idekube_container_access_token",
            "value": ACCESS_TOKEN,
            "url": cm.base_url,
        }])
        resp = page.goto(cm.base_url, wait_until="networkidle", timeout=30000)
        assert resp is not None
        assert resp.status != 401, "Cookie auth should not return 401"
        save_screenshot(request.node, page, f"{branch.replace('/', '-')}_auth_cookie")

    def test_header_auth(self, branch, container_pool, output_dir, lineup, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = http_requests.get(
            f"{cm.base_url}/",
            headers={"X-IDEKUBE-Container-Access-Token": ACCESS_TOKEN},
            timeout=10,
            allow_redirects=False,
        )
        assert resp.status_code != 401, "Header auth returned 401"

    def test_ssh_excluded_from_auth(self, branch, container_pool, output_dir, lineup, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = http_requests.get(f"{cm.base_url}/ssh", timeout=10, allow_redirects=False)
        assert resp.status_code != 401, f"/ssh should not require auth, got {resp.status_code}"

    def test_health_excluded_from_auth(self, branch, container_pool, output_dir, lineup, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = http_requests.get(f"{cm.base_url}/health", timeout=10)
        assert resp.status_code == 200, f"/health should not require auth, got {resp.status_code}"

    def test_token_link_redirect_is_relative(self, branch, container_pool, output_dir, lineup, request):
        """The cookie-setting redirect must not send HTTPS users to http://."""
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = http_requests.get(
            f"{cm.base_url}/some/page%20two?idekube-container-access-token={ACCESS_TOKEN}",
            headers=FORWARDED_HTTPS,
            timeout=10,
            allow_redirects=False,
        )
        assert resp.status_code == 302, f"Expected 302, got {resp.status_code}"
        location = resp.headers.get("Location")
        _assert_relative_location(location)
        # Original path kept with its percent-encoding; token query dropped.
        assert location.startswith("/some/page%20two"), location
        assert "access-token" not in location, location
        assert "idekube_container_access_token=" in resp.headers.get("Set-Cookie", "")

    @pytest.mark.parametrize("path", HOSTILE_PATHS)
    def test_token_link_redirect_stays_on_site(self, branch, path, container_pool, output_dir, lineup, request):
        """A crafted token-link path must not redirect off-site or inject headers."""
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = _raw_get(cm.base_url, f"{path}?idekube-container-access-token={ACCESS_TOKEN}")
        assert resp.status == 302, f"Expected 302, got {resp.status}"
        assert resp.getheader("X-Injected") is None, "CRLF in the path injected a response header"
        _assert_relative_location(resp.getheader("Location"))

    def test_wrong_token_rejected(self, branch, container_pool, output_dir, lineup, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = http_requests.get(
            f"{cm.base_url}/",
            headers={"X-IDEKUBE-Container-Access-Token": "wrong-token"},
            timeout=10,
            allow_redirects=False,
        )
        assert resp.status_code == 401, f"Wrong token should be rejected, got {resp.status_code}"

    @pytest.mark.parametrize("presented", NEAR_MISS_TOKENS)
    def test_near_miss_token_rejected(self, branch, presented, container_pool, output_dir, lineup, request):
        """Tokens compare exactly: case-sensitive, '.' literal, no placeholders."""
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        by_header = _status_with_header(cm, presented)
        by_cookie = http_requests.get(
            f"{cm.base_url}/", cookies={TOKEN_COOKIE: presented}, timeout=10, allow_redirects=False
        ).status_code
        by_query = http_requests.get(
            f"{cm.base_url}/?{TOKEN_PARAM}={presented}", timeout=10, allow_redirects=False
        ).status_code
        assert (by_header, by_cookie, by_query) == (401, 401, 401), (
            f"{presented!r} was accepted (header/cookie/query: {by_header}/{by_cookie}/{by_query})"
        )

    def test_token_cookie_flags(self, branch, container_pool, output_dir, lineup, request):
        """The cookie is HttpOnly, and Secure exactly when the ingress hop is HTTPS."""
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        url = f"{cm.base_url}/?{TOKEN_PARAM}={ACCESS_TOKEN}"

        plain = http_requests.get(url, timeout=10, allow_redirects=False).headers.get("Set-Cookie", "")
        assert re.search(r";\s*HttpOnly", plain), plain
        # Plain-HTTP access (localhost, LAN) would drop a Secure cookie.
        assert not re.search(r";\s*Secure", plain), plain

        tls = http_requests.get(
            url, headers=FORWARDED_HTTPS, timeout=10, allow_redirects=False
        ).headers.get("Set-Cookie", "")
        assert re.search(r";\s*HttpOnly", tls), tls
        assert re.search(r";\s*Secure", tls), tls

    def test_token_not_written_to_access_log(self, branch, container_pool, output_dir, lineup, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        http_requests.get(
            f"{cm.base_url}/idekube-logged-path?{TOKEN_PARAM}={ACCESS_TOKEN}",
            timeout=10,
            allow_redirects=False,
        )
        log = cm.exec_run(["cat", "/var/log/nginx/access.log"]).stdout
        assert "/idekube-logged-path" in log, "request missing from access.log (is logging on?)"
        assert ACCESS_TOKEN not in log, "access token written to access.log"

    def test_token_rotation_takes_effect(self, branch, container_pool, output_dir, lineup, request):
        """authn.sh renders from an untouched template, so a new token replaces the old one."""
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        rotated = "Rotated.Token-456"
        try:
            _render_token(cm, rotated)
            assert _status_with_header(cm, rotated) == 200, "rotated token not accepted"
            assert _status_with_header(cm, ACCESS_TOKEN) == 401, "old token still accepted"
        finally:
            _render_token(cm, ACCESS_TOKEN)
        assert _status_with_header(cm, ACCESS_TOKEN) == 200, "original token not restored"


class TestAuthFailClosed:
    """A token that cannot be configured must stop the container, not weaken auth."""

    def test_invalid_token_refuses_to_start(self, branch, lineup, request):
        image_ref = resolve_and_check(branch, lineup)
        started = subprocess.run(
            ["docker", "run", "-d", *container_labels(),
             "-e", "IDEKUBE_ACCESS_TOKEN=Invalid/Token=", image_ref],
            capture_output=True, text=True, check=True,
        )
        container_id = started.stdout.strip()
        try:
            waited = subprocess.run(
                ["docker", "wait", container_id], capture_output=True, text=True, timeout=180
            )
            logs = subprocess.run(
                ["docker", "logs", container_id], capture_output=True, text=True, timeout=30
            )
            output = logs.stdout + logs.stderr
            assert waited.stdout.strip() not in ("", "0"), f"container exited with {waited.stdout!r}"
            assert "invalid characters" in output, output[-2000:]
            assert "refusing to start" in output, output[-2000:]
        finally:
            subprocess.run(["docker", "rm", "-f", container_id], capture_output=True)


class TestRelativeRedirects:
    """nginx redirects outside the token flow must also stay relative."""

    def test_unknown_path_redirect_is_relative(self, branch, container_pool, output_dir, lineup, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = http_requests.get(
            f"{cm.base_url}/idekube-no-such-path",
            headers=FORWARDED_HTTPS,
            timeout=10,
            allow_redirects=False,
        )
        assert resp.status_code == 302, f"Expected 302, got {resp.status_code}"
        _assert_relative_location(resp.headers.get("Location"))
        assert resp.headers["Location"] == "/", resp.headers["Location"]

    def test_favicon_not_redirected(self, branch, container_pool, output_dir, lineup, request):
        cm = _get_auth_container(branch, lineup, container_pool, output_dir)
        attach_log(request.node, cm)
        resp = http_requests.get(
            f"{cm.base_url}/favicon.ico",
            headers=FORWARDED_HTTPS,
            timeout=10,
            allow_redirects=False,
        )
        assert resp.status_code == 204, f"Expected 204, got {resp.status_code}"
        assert "Location" not in resp.headers
