#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="${1:-charts/intel-arc-rebar}"
GITHUB_OWNER="${GITHUB_OWNER:-$(echo "${GITHUB_REPOSITORY:-}" | cut -d'/' -f1)}"
OCI_REGISTRY="oci://ghcr.io/${GITHUB_OWNER,,}/charts"
VERSION="${CHART_VERSION:-}"

if [[ -z "$GITHUB_OWNER" ]]; then
  echo "Error: Set GITHUB_OWNER=<your-github-username>"
  exit 1
fi

if [[ -n "${GHCR_TOKEN:-}" ]]; then
  echo "Logging into ghcr.io as ${GITHUB_ACTOR:-$GITHUB_OWNER}..."
  echo "$GHCR_TOKEN" | helm registry login ghcr.io -u "${GITHUB_ACTOR:-$GITHUB_OWNER}" --password-stdin
fi

echo "Linting Helm chart in ${CHART_DIR}..."
helm lint "$CHART_DIR"

PACKAGE_ARGS=("$CHART_DIR" --destination /tmp/helm-dist)
if [[ -n "$VERSION" ]]; then
  # Strip leading 'v' if git tag like v0.1.0 was passed
  CLEAN_VER="${VERSION#v}"
  PACKAGE_ARGS+=(--version "$CLEAN_VER" --app-version "$CLEAN_VER")
fi

mkdir -p /tmp/helm-dist
echo "Packaging Helm chart..."
PACKAGE_OUTPUT=$(helm package "${PACKAGE_ARGS[@]}")
TARBALL=$(echo "$PACKAGE_OUTPUT" | awk '{print $NF}')

echo "Pushing ${TARBALL} to ${OCI_REGISTRY}..."
helm push "$TARBALL" "$OCI_REGISTRY"
echo "Successfully pushed OCI Helm chart to ${OCI_REGISTRY}/$(basename "$CHART_DIR")"
