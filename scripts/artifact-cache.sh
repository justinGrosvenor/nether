#!/usr/bin/env bash
# Cache prebuilt guest artifacts (vmlinux, initramfs, disk.img) in S3 so a fresh
# bare-metal box does not have to rebuild the ~10-minute kernel each session.
# Run on a host with AWS credentials (e.g. the dev machine); the box exchanges
# these files with that host over scp during a session.
#
#   scripts/artifact-cache.sh push   # upload ./artifacts/* to S3
#   scripts/artifact-cache.sh pull   # download S3 -> ./artifacts/
#
# Bucket is per-account: nether-build-cache-<accountid> in $AWS_REGION.

set -euo pipefail
REGION="${AWS_REGION:-us-west-2}"
DIR="${ARTIFACT_DIR:-artifacts}"
FILES=(vmlinux initramfs disk.img)

ACCT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="nether-build-cache-${ACCT}"
PREFIX="s3://${BUCKET}/guest"

ensure_bucket() {
  if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
    echo "created bucket $BUCKET"
  fi
}

case "${1:-}" in
  push)
    ensure_bucket
    for f in "${FILES[@]}"; do
      if [ -f "$DIR/$f" ]; then
        aws s3 cp "$DIR/$f" "$PREFIX/$f" --only-show-errors && echo "pushed $f ($(du -h "$DIR/$f" | cut -f1))"
      else
        echo "skip $f (not in $DIR)"
      fi
    done
    ;;
  pull)
    mkdir -p "$DIR"
    for f in "${FILES[@]}"; do
      if aws s3 cp "$PREFIX/$f" "$DIR/$f" --only-show-errors 2>/dev/null; then
        echo "pulled $f"
      else
        echo "miss $f (not cached)"
      fi
    done
    ;;
  *)
    echo "usage: $0 {push|pull}   (bucket: $BUCKET)"
    exit 1
    ;;
esac
