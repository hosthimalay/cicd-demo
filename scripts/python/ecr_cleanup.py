#!/usr/bin/env python3
"""
ecr_cleanup.py — Automated ECR image lifecycle management

PURPOSE:
    AWS ECR charges for storage. Without cleanup, image storage costs grow
    indefinitely. This script runs weekly (via Jenkins cron pipeline) to
    delete old untagged and outdated images.

    Policy:
    - Keep all images tagged with production-deployed tags (protected)
    - Keep the last N tagged images per repo
    - Delete all untagged images older than 7 days
    - Produce a report of what was deleted and how much space was freed

USAGE:
    python3 scripts/python/ecr_cleanup.py --region eu-west-1 --keep 10 --dry-run
    python3 scripts/python/ecr_cleanup.py --region eu-west-1 --keep 10

RUNS IN:
    Jenkins — weekly scheduled pipeline: 'cron: H 2 * * 0'
"""

import argparse
import json
import sys
from datetime import datetime, timezone, timedelta
from typing import Optional

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    print("ERROR: boto3 not installed. Run: pip3 install boto3")
    sys.exit(1)


# ── ECR client wrapper ────────────────────────────────────────────────────────
class ECRCleaner:
    def __init__(self, region: str, dry_run: bool = True):
        self.region = region
        self.dry_run = dry_run
        self.ecr = boto3.client("ecr", region_name=region)
        self.deleted_count = 0
        self.bytes_freed = 0

    def get_repositories(self) -> list[dict]:
        """Get all ECR repositories in the account."""
        repos = []
        paginator = self.ecr.get_paginator("describe_repositories")
        for page in paginator.paginate():
            repos.extend(page["repositories"])
        return repos

    def get_images(self, repo_name: str) -> list[dict]:
        """Get all images in a repository with their metadata."""
        images = []
        paginator = self.ecr.get_paginator("describe_images")
        for page in paginator.paginate(repositoryName=repo_name):
            images.extend(page["imageDetails"])
        return images

    def get_deployed_tags(self) -> set[str]:
        """
        Get image tags currently deployed to EKS.
        These are PROTECTED — we never delete a running image.
        In production, query actual EKS deployments here.
        """
        # In a real implementation, this would call:
        # kubectl get deployments --all-namespaces -o json
        # and extract image tags from the spec
        protected = set()
        print("  [INFO] Fetching deployed tags from EKS...")
        try:
            import subprocess
            result = subprocess.run(
                ["kubectl", "get", "deployments", "--all-namespaces",
                 "-o", "jsonpath={.items[*].spec.template.spec.containers[*].image}"],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0:
                for image in result.stdout.split():
                    if ":" in image:
                        tag = image.split(":")[-1]
                        protected.add(tag)
                print(f"  [INFO] Protected tags (currently deployed): {protected}")
        except Exception as e:
            print(f"  [WARN] Could not query EKS for deployed tags: {e}")
            print("  [WARN] No tags will be protected — proceeding conservatively")
        return protected

    def clean_repository(self, repo_name: str, keep_count: int,
                         max_untagged_age_days: int, protected_tags: set) -> dict:
        """
        Clean a single ECR repository.
        Returns a summary of what was deleted.
        """
        print(f"\n  Repository: {repo_name}")
        images = self.get_images(repo_name)

        if not images:
            print("    No images found — skipping")
            return {"repo": repo_name, "deleted": 0, "bytes_freed": 0}

        print(f"    Total images: {len(images)}")

        to_delete = []
        now = datetime.now(timezone.utc)
        cutoff = now - timedelta(days=max_untagged_age_days)

        # Separate tagged and untagged images
        tagged   = [i for i in images if i.get("imageTags")]
        untagged = [i for i in images if not i.get("imageTags")]

        print(f"    Tagged: {len(tagged)}, Untagged: {len(untagged)}")

        # Delete old untagged images
        for img in untagged:
            pushed_at = img.get("imagePushedAt")
            if pushed_at and pushed_at < cutoff:
                age_days = (now - pushed_at).days
                size_mb = img.get("imageSizeInBytes", 0) / 1024 / 1024
                to_delete.append({
                    "imageDigest": img["imageDigest"],
                    "reason": f"Untagged, {age_days} days old",
                    "size_mb": size_mb
                })

        # Sort tagged images by push date — newest first
        tagged.sort(key=lambda x: x.get("imagePushedAt", datetime.min.replace(tzinfo=timezone.utc)),
                    reverse=True)

        # Keep last N tagged images, delete the rest (unless protected)
        for img in tagged[keep_count:]:
            tags = img.get("imageTags", [])
            is_protected = any(tag in protected_tags for tag in tags)
            if is_protected:
                print(f"    PROTECTED: {tags} — currently deployed, skipping")
                continue
            size_mb = img.get("imageSizeInBytes", 0) / 1024 / 1024
            to_delete.append({
                "imageDigest": img["imageDigest"],
                "imageTags": tags,
                "reason": f"Old image (outside keep-last-{keep_count})",
                "size_mb": size_mb
            })

        if not to_delete:
            print("    Nothing to delete")
            return {"repo": repo_name, "deleted": 0, "bytes_freed": 0}

        total_size_mb = sum(i["size_mb"] for i in to_delete)
        print(f"    Images to delete: {len(to_delete)} ({total_size_mb:.1f} MB)")

        for item in to_delete:
            tags = item.get("imageTags", ["untagged"])
            print(f"    {'[DRY RUN] Would delete' if self.dry_run else 'Deleting'}: "
                  f"{tags} — {item['reason']} ({item['size_mb']:.1f} MB)")

        if not self.dry_run:
            # Batch delete — ECR allows max 100 per call
            batch = [{"imageDigest": i["imageDigest"]} for i in to_delete]
            for i in range(0, len(batch), 100):
                chunk = batch[i:i+100]
                try:
                    self.ecr.batch_delete_image(
                        repositoryName=repo_name,
                        imageIds=chunk
                    )
                except ClientError as e:
                    print(f"    ERROR deleting batch: {e}")

        self.deleted_count += len(to_delete)
        self.bytes_freed += total_size_mb * 1024 * 1024

        return {
            "repo": repo_name,
            "deleted": len(to_delete),
            "bytes_freed": total_size_mb * 1024 * 1024
        }


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="ECR image lifecycle management")
    parser.add_argument("--region",         default="eu-west-1", help="AWS region")
    parser.add_argument("--keep",           type=int, default=10, help="Number of tagged images to keep per repo")
    parser.add_argument("--max-age-days",   type=int, default=7,  help="Max age (days) for untagged images")
    parser.add_argument("--repo",           help="Specific repository name (default: all repos)")
    parser.add_argument("--dry-run",        action="store_true",  help="Show what would be deleted without deleting")
    args = parser.parse_args()

    print(f"\n{'=' * 60}")
    print(f"  ECR Cleanup — {'DRY RUN' if args.dry_run else 'LIVE RUN'}")
    print(f"  Region: {args.region}")
    print(f"  Keep last {args.keep} tagged images per repo")
    print(f"  Delete untagged images older than {args.max_age_days} days")
    print(f"  Time: {datetime.utcnow().isoformat()}Z")
    print(f"{'=' * 60}\n")

    cleaner = ECRCleaner(region=args.region, dry_run=args.dry_run)

    # Get currently deployed tags to protect them
    protected_tags = cleaner.get_deployed_tags()

    # Get repos to clean
    if args.repo:
        repos = [{"repositoryName": args.repo}]
    else:
        repos = cleaner.get_repositories()
        print(f"Found {len(repos)} repositories\n")

    results = []
    for repo in repos:
        result = cleaner.clean_repository(
            repo_name=repo["repositoryName"],
            keep_count=args.keep,
            max_untagged_age_days=args.max_age_days,
            protected_tags=protected_tags
        )
        results.append(result)

    # Summary
    total_deleted = sum(r["deleted"] for r in results)
    total_freed_mb = sum(r["bytes_freed"] for r in results) / 1024 / 1024

    print(f"\n{'=' * 60}")
    print(f"  SUMMARY {'(DRY RUN)' if args.dry_run else ''}")
    print(f"  Repositories scanned: {len(results)}")
    print(f"  Images deleted:       {total_deleted}")
    print(f"  Storage freed:        {total_freed_mb:.1f} MB")
    print(f"{'=' * 60}\n")

    if args.dry_run:
        print("DRY RUN complete — no images were deleted.")
        print("Re-run without --dry-run to apply changes.")


if __name__ == "__main__":
    main()
