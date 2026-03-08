#!/usr/bin/env python3
"""
pipeline_monitor.py — Jenkins pipeline health monitor

PURPOSE:
    Queries the Jenkins API to get pipeline run statistics.
    Calculates DORA metrics (deployment frequency, success rate).
    Sends a daily digest to Slack so the team can see CI/CD health at a glance.

USAGE:
    python3 scripts/python/pipeline_monitor.py \
        --jenkins-url https://jenkins.example.com \
        --job cicd-demo \
        --days 7

RUNS IN:
    Jenkins — daily cron pipeline at 08:00 to generate morning digest
"""

import argparse
import json
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta
from dataclasses import dataclass, field
from typing import Optional
import base64
import os


@dataclass
class BuildRecord:
    number: int
    result: str            # SUCCESS, FAILURE, UNSTABLE, ABORTED
    duration_ms: int
    timestamp_ms: int
    branch: str = "unknown"
    commit: str = "unknown"

    @property
    def timestamp(self) -> datetime:
        return datetime.fromtimestamp(self.timestamp_ms / 1000, tz=timezone.utc)

    @property
    def duration_minutes(self) -> float:
        return self.duration_ms / 1000 / 60

    @property
    def passed(self) -> bool:
        return self.result == "SUCCESS"


def jenkins_get(base_url: str, path: str,
                username: Optional[str], token: Optional[str]) -> dict:
    """Make an authenticated GET request to the Jenkins API."""
    url = f"{base_url}{path}"
    req = urllib.request.Request(url)

    if username and token:
        creds = base64.b64encode(f"{username}:{token}".encode()).decode()
        req.add_header("Authorization", f"Basic {creds}")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"Jenkins API error {e.code}: {url}")
        return {}
    except Exception as e:
        print(f"Request failed: {e}: {url}")
        return {}


def get_builds(jenkins_url: str, job_name: str,
               username: Optional[str], token: Optional[str],
               days: int = 7) -> list[BuildRecord]:
    """
    Fetch build history from Jenkins for the last N days.
    """
    path = f"/job/{job_name}/api/json?tree=builds[number,result,duration,timestamp,actions[parameters[*]]]"
    data = jenkins_get(jenkins_url, path, username, token)

    if not data or "builds" not in data:
        print(f"No builds found for job: {job_name}")
        return []

    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    records = []

    for build in data["builds"]:
        if not build.get("timestamp"):
            continue

        ts = datetime.fromtimestamp(build["timestamp"] / 1000, tz=timezone.utc)
        if ts < cutoff:
            continue

        # Extract branch from build parameters if available
        branch = "unknown"
        for action in build.get("actions", []):
            for param in action.get("parameters", []):
                if param.get("name") in ("BRANCH", "GIT_BRANCH", "branch"):
                    branch = param.get("value", "unknown")

        records.append(BuildRecord(
            number=build["number"],
            result=build.get("result") or "IN_PROGRESS",
            duration_ms=build.get("duration", 0),
            timestamp_ms=build["timestamp"],
            branch=branch
        ))

    return sorted(records, key=lambda b: b.timestamp_ms, reverse=True)


def calculate_metrics(builds: list[BuildRecord], days: int) -> dict:
    """
    Calculate DORA-aligned CI/CD metrics from build history.
    """
    if not builds:
        return {}

    completed = [b for b in builds if b.result in ("SUCCESS", "FAILURE", "UNSTABLE")]
    successful = [b for b in builds if b.passed]
    failed     = [b for b in builds if b.result == "FAILURE"]

    total = len(completed)
    success_rate = (len(successful) / total * 100) if total > 0 else 0

    avg_duration = (
        sum(b.duration_minutes for b in successful) / len(successful)
        if successful else 0
    )

    # Deployment frequency: successful builds per day
    deploy_freq = len(successful) / days if days > 0 else 0

    # Mean time to recovery: average gap between a failure and the next success
    mttr_minutes = None
    sorted_builds = sorted(completed, key=lambda b: b.timestamp_ms)
    failure_time = None
    mttr_samples = []
    for build in sorted_builds:
        if build.result == "FAILURE" and failure_time is None:
            failure_time = build.timestamp
        elif build.passed and failure_time is not None:
            recovery_minutes = (build.timestamp - failure_time).total_seconds() / 60
            mttr_samples.append(recovery_minutes)
            failure_time = None

    if mttr_samples:
        mttr_minutes = sum(mttr_samples) / len(mttr_samples)

    return {
        "period_days": days,
        "total_builds": total,
        "successful": len(successful),
        "failed": len(failed),
        "success_rate_pct": round(success_rate, 1),
        "avg_duration_minutes": round(avg_duration, 1),
        "deploy_frequency_per_day": round(deploy_freq, 2),
        "mttr_minutes": round(mttr_minutes, 0) if mttr_minutes else None,
        "last_success": successful[0].timestamp.isoformat() if successful else None,
        "last_failure": failed[0].timestamp.isoformat() if failed else None,
    }


def send_slack_digest(webhook_url: str, job_name: str, metrics: dict, builds: list[BuildRecord]):
    """Send a formatted Slack digest with pipeline health metrics."""
    if not webhook_url:
        return

    recent = builds[:5]  # Last 5 builds

    status_emoji = "✅" if metrics.get("success_rate_pct", 0) >= 80 else "⚠️"

    recent_text = "\n".join([
        f"  {'✅' if b.passed else '❌'} #{b.number} ({b.result}) — {b.duration_minutes:.1f}m — {b.timestamp.strftime('%d %b %H:%M')}"
        for b in recent
    ])

    message = {
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text",
                         "text": f"{status_emoji} Jenkins Pipeline Report — {job_name}"}
            },
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": f"*Success Rate:*\n{metrics.get('success_rate_pct')}%"},
                    {"type": "mrkdwn", "text": f"*Deploy Frequency:*\n{metrics.get('deploy_frequency_per_day')}/day"},
                    {"type": "mrkdwn", "text": f"*Avg Build Time:*\n{metrics.get('avg_duration_minutes')}m"},
                    {"type": "mrkdwn", "text": f"*MTTR:*\n{metrics.get('mttr_minutes', 'N/A')}m"},
                ]
            },
            {
                "type": "section",
                "text": {"type": "mrkdwn",
                         "text": f"*Last {len(recent)} Builds:*\n{recent_text}"}
            }
        ]
    }

    try:
        data = json.dumps(message).encode("utf-8")
        req = urllib.request.Request(webhook_url, data=data,
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10)
        print("Slack digest sent successfully")
    except Exception as e:
        print(f"Failed to send Slack digest: {e}")


def main():
    parser = argparse.ArgumentParser(description="Jenkins pipeline health monitor")
    parser.add_argument("--jenkins-url", required=True, help="Jenkins base URL")
    parser.add_argument("--job",         required=True, help="Jenkins job name")
    parser.add_argument("--days",        type=int, default=7, help="Days of history to analyse")
    parser.add_argument("--slack",       help="Slack webhook URL for digest")
    args = parser.parse_args()

    # Read credentials from environment (never pass on command line)
    username = os.environ.get("JENKINS_USER")
    token    = os.environ.get("JENKINS_TOKEN")

    print(f"\n{'=' * 60}")
    print(f"  Jenkins Pipeline Monitor")
    print(f"  Job: {args.job} | Last {args.days} days")
    print(f"{'=' * 60}\n")

    builds = get_builds(args.jenkins_url, args.job, username, token, args.days)

    if not builds:
        print("No builds found. Check Jenkins URL and credentials.")
        sys.exit(1)

    print(f"Found {len(builds)} builds in last {args.days} days\n")

    metrics = calculate_metrics(builds, args.days)

    print("DORA Metrics:")
    print(f"  Success Rate:        {metrics.get('success_rate_pct')}%")
    print(f"  Deploy Frequency:    {metrics.get('deploy_frequency_per_day')}/day")
    print(f"  Avg Build Duration:  {metrics.get('avg_duration_minutes')} minutes")
    print(f"  MTTR:                {metrics.get('mttr_minutes', 'N/A')} minutes")
    print(f"  Last Success:        {metrics.get('last_success', 'None')}")
    print(f"  Last Failure:        {metrics.get('last_failure', 'None')}")

    # Send Slack digest if webhook provided
    slack_url = args.slack or os.environ.get("SLACK_WEBHOOK")
    if slack_url:
        send_slack_digest(slack_url, args.job, metrics, builds)

    # Exit with error code if pipeline health is poor
    if metrics.get("success_rate_pct", 0) < 70:
        print(f"\nWARNING: Success rate {metrics['success_rate_pct']}% is below 70% threshold")
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
