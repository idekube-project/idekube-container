"""Pytest configuration: fixtures, CLI options, report hooks, and container management.

Tests are organized per-branch. Each branch gets the full test suite run against it.
With pytest-xdist, up to MAX_PARALLEL branches are tested simultaneously.
"""

from __future__ import annotations

import base64
import logging
import os
import subprocess
from pathlib import Path

import pytest

from helpers.constants import (
    BROWSER_TESTABLE_SERVICES,
    DIND_BRANCHES,
    DESKTOP_BRANCHES,
    MAX_PARALLEL,
    PRIVILEGED_BRANCHES,
    get_expected_health,
)
from helpers.containers import (
    ContainerManager,
    allocate_port,
    cleanup_own_containers,
    cleanup_stale_containers,
)
from helpers.images import (
    get_flavor,
    get_lineup_branches,
    is_image_available,
    resolve_image_ref,
)

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / ".cache" / "test-output"

# SSH key pair for testing IDEKUBE_AUTHORIZED_KEYS
TEST_SSH_PUBKEY = (
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForIDEKubeContainerTests idekube-test"
)
TEST_SSH_AUTHORIZED_KEYS_B64 = base64.b64encode(TEST_SSH_PUBKEY.encode()).decode()

# Mixed case and a "." on purpose: the gateway must compare tokens
# case-sensitively and treat "." literally (not as a regex wildcard).
ACCESS_TOKEN = "Idekube.Test_Token-123"


# ---------------------------------------------------------------------------
# CLI options
# ---------------------------------------------------------------------------


def pytest_addoption(parser):
    parser.addoption(
        "--lineup",
        default="universal",
        choices=["universal", "ascend"],
        help="Image lineup to test (universal or ascend)",
    )
    parser.addoption(
        "--branch",
        default="",
        help="Restrict tests to these branches, comma-separated (e.g. featured/base,coder/base). Empty = all branches.",
    )
    parser.addoption(
        "--require-images",
        action="store_true",
        default=os.environ.get("IDEKUBE_REQUIRE_IMAGES", "") not in ("", "0", "false"),
        help="Fail instead of skipping when a selected branch's image is missing, and fail when no test passed "
        "(CI: a run that tested nothing must not look green). Also enabled by IDEKUBE_REQUIRE_IMAGES=1.",
    )
    parser.addoption(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help="Directory for test output (screenshots, logs, reports)",
    )


# ---------------------------------------------------------------------------
# Session-scoped fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def lineup(request) -> str:
    return request.config.getoption("--lineup")


@pytest.fixture(scope="session")
def output_dir(request) -> Path:
    path = Path(request.config.getoption("--output-dir"))
    path.mkdir(parents=True, exist_ok=True)
    (path / "screenshots").mkdir(exist_ok=True)
    (path / "logs").mkdir(exist_ok=True)
    return path


@pytest.fixture(scope="session")
def nvidia_runtime_available() -> bool:
    """Check if NVIDIA container runtime is available."""
    try:
        result = subprocess.run(
            ["docker", "info", "--format", "{{json .Runtimes}}"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return "nvidia" in result.stdout
    except Exception:
        return False


def pytest_sessionstart(session):
    """Sweep leftovers of interrupted earlier runs, once per test run.

    xdist workers have ``workerinput``; only the controller (or a plain,
    non-xdist session) acts as the coordinator, so workers never remove each
    other's containers.
    """
    if not hasattr(session.config, "workerinput"):
        cleanup_stale_containers()
        _require_images(session.config)


def _require_images(config) -> None:
    """With --require-images, stop before running anything if an image is missing."""
    if not config.getoption("--require-images"):
        return
    lineup = config.getoption("--lineup")
    missing = [
        ref
        for ref in (resolve_image_ref(branch, lineup) for branch in _filtered_branches(config))
        if not is_image_available(ref)
    ]
    if missing:
        pytest.exit("--require-images: images not present locally:\n  " + "\n  ".join(missing), returncode=3)


def pytest_sessionfinish(session, exitstatus):
    """With --require-images, a session in which no test passed is a failure."""
    config = session.config
    if hasattr(config, "workerinput") or not config.getoption("--require-images"):
        return
    reporter = config.pluginmanager.get_plugin("terminalreporter")
    passed = len(reporter.stats.get("passed", [])) if reporter else 0
    if passed == 0 and exitstatus == 0:
        logger.error("--require-images: no test passed")
        session.exitstatus = 1


@pytest.fixture(scope="session", autouse=True)
def _cleanup_own(output_dir):
    """At session end, remove every container this worker started."""
    yield
    cleanup_own_containers()


# ---------------------------------------------------------------------------
# Container pools: keyed by "{branch}" / "{branch}:auth" / "{branch}:env"
# Session-scoped so containers are reused across all tests within a worker.
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def container_pool(output_dir) -> dict[str, ContainerManager]:
    """Lazy-started container pool. Cleaned up at session end."""
    pool: dict[str, ContainerManager] = {}
    yield pool
    for cm in pool.values():
        cm.stop()


def get_or_start_container(
    pool: dict[str, ContainerManager],
    branch: str,
    image_ref: str,
    output_dir: Path,
    extra_env: dict[str, str] | None = None,
    privileged: bool | None = None,
    pool_key: str | None = None,
) -> ContainerManager:
    """Get a running container from pool, or start a new one."""
    key = pool_key or branch
    if key in pool:
        return pool[key]

    if privileged is None:
        privileged = branch in PRIVILEGED_BRANCHES

    cm = ContainerManager(
        image_ref=image_ref,
        branch=branch,
        output_dir=output_dir,
        extra_env=extra_env,
        privileged=privileged,
        extra_ports={2222: allocate_port()},
    )
    cm.start()
    cm.wait_healthy()
    pool[key] = cm
    return cm


# ---------------------------------------------------------------------------
# Parametrize helpers
# ---------------------------------------------------------------------------


def _filtered_branches(config) -> list[str]:
    """Return branches to test, honoring the --branch filter if set."""
    lineup = config.getoption("--lineup")
    wanted = [b for b in config.getoption("--branch").split(",") if b]
    branches = get_lineup_branches(lineup)
    if wanted:
        unknown = [b for b in wanted if b not in branches]
        if unknown:
            raise ValueError(
                f"Branch(es) {unknown} not in lineup '{lineup}'. "
                f"Available: {branches}"
            )
        branches = [b for b in branches if b in wanted]
    return branches


def get_branch_params(config) -> list:
    """Generate pytest params for all branches (filtered by --branch if set)."""
    lineup = config.getoption("--lineup")
    branches = _filtered_branches(config)
    params = []
    for branch in branches:
        ref = resolve_image_ref(branch, lineup)
        available = is_image_available(ref)
        marks = [] if available else [pytest.mark.skip(reason=f"Image not found: {ref}")]
        params.append(pytest.param(branch, id=branch, marks=marks))
    return params


def get_service_params(config) -> list:
    """Generate pytest params for (branch, service) combinations."""
    lineup = config.getoption("--lineup")
    branches = _filtered_branches(config)
    params = []
    for branch in branches:
        ref = resolve_image_ref(branch, lineup)
        available = is_image_available(ref)
        health = get_expected_health(branch)
        for svc_name, svc_info in health["services"].items():
            if svc_name not in BROWSER_TESTABLE_SERVICES:
                continue
            if svc_info.get("path") is None:
                continue
            marks = [] if available else [pytest.mark.skip(reason=f"Image not found: {ref}")]
            params.append(
                pytest.param(branch, svc_name, id=f"{branch}/{svc_name}", marks=marks)
            )
    return params


# ---------------------------------------------------------------------------
# pytest-html report hooks: attach screenshots and logs on failure
# ---------------------------------------------------------------------------


_screenshot_key = pytest.StashKey[str]()
_log_key = pytest.StashKey[str]()


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()

    if report.when != "call":
        return

    extras = getattr(report, "extras", [])

    screenshot_path = item.stash.get(_screenshot_key, None)
    if screenshot_path and Path(screenshot_path).exists():
        try:
            from pytest_html import extras as html_extras

            extras.append(html_extras.image(str(screenshot_path)))
        except ImportError:
            pass

    if report.failed:
        log_path = item.stash.get(_log_key, None)
        if log_path and Path(log_path).exists():
            try:
                from pytest_html import extras as html_extras

                log_text = Path(log_path).read_text()[-5000:]
                extras.append(html_extras.text(log_text, name="Container Log"))
            except ImportError:
                pass

    report.extras = extras


def save_screenshot(item, page, name: str) -> Path | None:
    """Save a Playwright screenshot and register it for the report."""
    try:
        out = item.config.getoption("--output-dir")
        path = Path(out) / "screenshots" / f"{name}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(path))
        item.stash[_screenshot_key] = str(path)
        return path
    except Exception as exc:
        logger.warning("Failed to save screenshot %s: %s", name, exc)
        return None


def attach_log(item, container: ContainerManager) -> None:
    """Register container log path for report attachment on failure."""
    log_path = container.output_dir / "logs" / f"{container.slug}.log"
    item.stash[_log_key] = str(log_path)


# ---------------------------------------------------------------------------
# Helper to resolve image for a branch within a test
# ---------------------------------------------------------------------------


def _extract_branch(item) -> str | None:
    """Extract the branch parameter from a test item."""
    if hasattr(item, "callspec"):
        return item.callspec.params.get("branch")
    return None


def pytest_collection_modifyitems(items):
    """Reorder tests so all tests for the same branch run together (branch-first).

    Also assigns xdist groups so each worker handles one branch at a time.
    This ensures the container pool (session-scoped per worker) is shared
    across all tests for a given branch, avoiding redundant container starts.
    """
    # Group items by branch
    from collections import defaultdict

    branch_groups: dict[str, list] = defaultdict(list)
    no_branch: list = []

    for item in items:
        branch = _extract_branch(item)
        if branch:
            branch_groups[branch].append(item)
            item.add_marker(pytest.mark.xdist_group(branch))
        else:
            no_branch.append(item)

    # Rebuild items list: branch-first ordering
    items.clear()
    items.extend(no_branch)
    for branch in sorted(branch_groups.keys()):
        items.extend(branch_groups[branch])


def resolve_and_check(branch: str, lineup: str) -> str:
    """Resolve image ref and skip test if not available."""
    ref = resolve_image_ref(branch, lineup)
    if not is_image_available(ref):
        pytest.skip(f"Image not found: {ref}")
    return ref
