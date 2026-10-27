#!/usr/bin/env bash
# Build the SIPp image for the platform of this host.
#
# The tag is <IMAGE>:<SIPp version>-ubuntu<Ubuntu version without the dot>,
# for example ghcr.io/miarec/sipp:3.8.0-ubuntu2404. The versions come from the
# ARG lines at the top of the Dockerfile.
#
# Usage: ./build.sh              build the image and print its tag
#        ./build.sh --print-tag  print the tag only
#
# Environment:
#   IMAGE           repository, default ghcr.io/miarec/sipp
#   TAG_SUFFIX      appended to the tag, for example -arm64
#   IMAGE_REVISION  commit for the revision label, default the HEAD of this
#                   repository
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")" && pwd)

dockerfile_arg() {
  sed -n "s/^ARG $1=//p" "$repo_dir/Dockerfile"
}

sipp_version=$(dockerfile_arg SIPP_VERSION)
ubuntu_version=$(dockerfile_arg UBUNTU_VERSION)
if [[ -z "$sipp_version" || -z "$ubuntu_version" ]]; then
  echo "The Dockerfile has no ARG SIPP_VERSION=... or ARG UBUNTU_VERSION=... line" >&2
  exit 1
fi
tag="${IMAGE:-ghcr.io/miarec/sipp}:${sipp_version}-ubuntu${ubuntu_version//./}${TAG_SUFFIX:-}"

if [[ "${1:-}" == "--print-tag" ]]; then
  echo "$tag"
  exit 0
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--print-tag]" >&2
  exit 2
fi

labels=(--label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
revision=${IMAGE_REVISION:-$(git -C "$repo_dir" rev-parse --verify --quiet HEAD || true)}
if [[ -n "$revision" ]]; then
  labels+=(--label "org.opencontainers.image.revision=${revision}")
fi

# --pull takes the current ubuntu image, with its latest security updates.
docker build --pull "${labels[@]}" --tag "$tag" "$repo_dir" >&2
echo "$tag"
