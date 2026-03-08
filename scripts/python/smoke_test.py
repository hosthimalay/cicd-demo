#!/usr/bin/env python3
"""
smoke_test.py — Post-deployment smoke test runner

PURPOSE:
    Runs after every deployment in Jenkins to verify the application
    is alive and serving traffic correctly. If any check fails, the
    Jenkins stage fails and alerts the team.

USAGE:
    python3 scripts/python/smoke_test.py --url https://staging.example.com --env staging
    python3 scripts/python/smoke_test.py --url https://example.com --env production

RUNS IN:
    Jenkins pipeline — 'post { success { ... } }' block after deploy stage
"""

import argparse
import json
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
import urllib.request
import urllib.error


# ── Test result data structure ────────────────────────────────────────────────
@dataclass
class TestResult:
    name: str
    passed: bool
    duration_ms: float
    message: str
    details: Optional[str] = None


@dataclass
class SmokeTestReport:
    environment: str
    base_url: str
    started_at: str
    results: list = field(default_factory=list)

    @property
    def passed(self) -> int:
        return sum(1 for r in self.results if r.passed)

    @property
    def failed(self) -> int:
        return sum(1 for r in self.results if not r.passed)

    @property
    def all_passed(self) -> bool:
        return self.failed == 0


# ── HTTP helper ───────────────────────────────────────────────────────────────
def http_get(url: str, timeout: int = 10) -> tuple[int, dict, float]:
    """
    Make an HTTP GET request and return (status_code, response_body, duration_seconds).
    Returns (0, {}, duration) if the request fails entirely.
    """
    start = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cicd-smoke-test/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = response.read().decode("utf-8")
            duration = time.time() - start
            try:
                return response.status, json.loads(body), duration
            except json.JSONDecodeError:
                return response.status, {"raw": body}, duration
    except urllib.error.HTTPError as e:
        duration = time.time() - start
        return e.code, {}, duration
    except Exception as e:
        duration = time.time() - start
        return 0, {"error": str(e)}, duration


# ── Individual smoke test functions ──────────────────────────────────────────
def test_health_endpoint(base_url: str) -> TestResult:
    """
    The most basic test — is the app alive?
    /health must return 200 with status=UP
    """
    start = time.time()
    url = f"{base_url}/health"
    status, body, duration_s = http_get(url)
    duration_ms = duration_s * 1000

    if status != 200:
        return TestResult(
            name="Health Endpoint",
            passed=False,
            duration_ms=duration_ms,
            message=f"Expected HTTP 200, got {status}",
            details=f"URL: {url}"
        )

    if body.get("status") != "UP":
        return TestResult(
            name="Health Endpoint",
            passed=False,
            duration_ms=duration_ms,
            message=f"Expected status=UP, got status={body.get('status')}",
            details=json.dumps(body)
        )

    return TestResult(
        name="Health Endpoint",
        passed=True,
        duration_ms=duration_ms,
        message=f"HTTP 200, status=UP ({duration_ms:.0f}ms)"
    )


def test_readiness_endpoint(base_url: str) -> TestResult:
    """
    Kubernetes readiness probe endpoint — must return 200.
    If this fails, Kubernetes won't route traffic to the pod.
    """
    start = time.time()
    url = f"{base_url}/ready"
    status, body, duration_s = http_get(url)
    duration_ms = duration_s * 1000

    passed = status == 200 and body.get("ready") is True
    return TestResult(
        name="Readiness Endpoint",
        passed=passed,
        duration_ms=duration_ms,
        message=f"HTTP {status}, ready={body.get('ready')} ({duration_ms:.0f}ms)"
        if passed else f"Expected ready=true, got HTTP {status}",
        details=json.dumps(body) if not passed else None
    )


def test_root_endpoint(base_url: str) -> TestResult:
    """
    Root / endpoint — basic API availability check.
    """
    url = f"{base_url}/"
    status, body, duration_s = http_get(url)
    duration_ms = duration_s * 1000

    passed = status == 200 and "message" in body
    return TestResult(
        name="Root Endpoint",
        passed=passed,
        duration_ms=duration_ms,
        message=f"HTTP {status} ({duration_ms:.0f}ms)" if passed else f"HTTP {status} — unexpected response",
        details=json.dumps(body) if not passed else None
    )


def test_api_info(base_url: str) -> TestResult:
    """
    /api/info — checks that app metadata is returned correctly.
    Critical for verifying the RIGHT version was deployed.
    """
    url = f"{base_url}/api/info"
    status, body, duration_s = http_get(url)
    duration_ms = duration_s * 1000

    if status != 200:
        return TestResult(
            name="API Info Endpoint",
            passed=False,
            duration_ms=duration_ms,
            message=f"HTTP {status} (expected 200)"
        )

    required_fields = ["app", "version", "node"]
    missing = [f for f in required_fields if f not in body]

    if missing:
        return TestResult(
            name="API Info Endpoint",
            passed=False,
            duration_ms=duration_ms,
            message=f"Missing fields in response: {missing}",
            details=json.dumps(body)
        )

    return TestResult(
        name="API Info Endpoint",
        passed=True,
        duration_ms=duration_ms,
        message=f"v{body.get('version')} on {body.get('node')} ({duration_ms:.0f}ms)"
    )


def test_response_time(base_url: str, threshold_ms: float = 2000) -> TestResult:
    """
    Performance gate — health endpoint must respond within threshold.
    Catches deployments where app starts but is degraded/slow.
    """
    url = f"{base_url}/health"
    # Make 3 requests and use the average
    times = []
    for _ in range(3):
        _, _, duration_s = http_get(url)
        times.append(duration_s * 1000)
        time.sleep(0.2)

    avg_ms = sum(times) / len(times)
    passed = avg_ms < threshold_ms

    return TestResult(
        name="Response Time",
        passed=passed,
        duration_ms=avg_ms,
        message=f"Average {avg_ms:.0f}ms (threshold: {threshold_ms:.0f}ms)",
        details=f"Individual times: {[f'{t:.0f}ms' for t in times]}" if not passed else None
    )


def test_api_items(base_url: str) -> TestResult:
    """
    /api/items — functional test that verifies actual business logic works.
    This is the most important test — it exercises the application logic.
    """
    url = f"{base_url}/api/items"
    status, body, duration_s = http_get(url)
    duration_ms = duration_s * 1000

    if status != 200:
        return TestResult(
            name="API Items Endpoint",
            passed=False,
            duration_ms=duration_ms,
            message=f"HTTP {status} (expected 200)"
        )

    items = body.get("items", [])
    if not isinstance(items, list) or len(items) == 0:
        return TestResult(
            name="API Items Endpoint",
            passed=False,
            duration_ms=duration_ms,
            message="Expected non-empty items array",
            details=json.dumps(body)
        )

    return TestResult(
        name="API Items Endpoint",
        passed=True,
        duration_ms=duration_ms,
        message=f"Returned {len(items)} items ({duration_ms:.0f}ms)"
    )


# ── Test runner ───────────────────────────────────────────────────────────────
def run_smoke_tests(base_url: str, environment: str) -> SmokeTestReport:
    """Run all smoke tests and collect results."""
    report = SmokeTestReport(
        environment=environment,
        base_url=base_url,
        started_at=datetime.utcnow().isoformat() + "Z"
    )

    # Define all tests to run
    tests = [
        lambda: test_health_endpoint(base_url),
        lambda: test_readiness_endpoint(base_url),
        lambda: test_root_endpoint(base_url),
        lambda: test_api_info(base_url),
        lambda: test_api_items(base_url),
        lambda: test_response_time(base_url),
    ]

    for test_fn in tests:
        result = test_fn()
        report.results.append(result)
        status_icon = "✓" if result.passed else "✗"
        print(f"  {status_icon} {result.name}: {result.message}")
        if result.details:
            print(f"      Details: {result.details}")

    return report


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Post-deployment smoke test runner")
    parser.add_argument("--url",      required=True, help="Base URL of the deployed app")
    parser.add_argument("--env",      required=True, help="Environment name (staging/production)")
    parser.add_argument("--retries",  type=int, default=3, help="Number of retry attempts")
    parser.add_argument("--wait",     type=int, default=10, help="Seconds to wait between retries")
    args = parser.parse_args()

    print(f"\n{'=' * 60}")
    print(f"  Smoke Tests — {args.env.upper()}")
    print(f"  URL: {args.url}")
    print(f"  Time: {datetime.utcnow().isoformat()}Z")
    print(f"{'=' * 60}\n")

    # Retry logic — app may still be starting up when Jenkins runs this
    for attempt in range(1, args.retries + 1):
        if attempt > 1:
            print(f"\nRetry {attempt}/{args.retries} — waiting {args.wait}s...")
            time.sleep(args.wait)

        report = run_smoke_tests(args.url, args.env)

        if report.all_passed:
            break

    # Print summary
    print(f"\n{'=' * 60}")
    print(f"  RESULTS: {report.passed} passed, {report.failed} failed")
    print(f"{'=' * 60}\n")

    if not report.all_passed:
        print("SMOKE TESTS FAILED — Deployment may be broken")
        print("Failed tests:")
        for r in report.results:
            if not r.passed:
                print(f"  - {r.name}: {r.message}")
        sys.exit(1)
    else:
        print("ALL SMOKE TESTS PASSED — Deployment looks healthy")
        sys.exit(0)


if __name__ == "__main__":
    main()
