#!/usr/bin/env bash
# Build the web UI + Supertonic images locally and push them to a registry
# (e.g. quay.io) — for clusters WITHOUT an internal image registry (bare-metal /
# disconnected). Then deploy with:
#   ./full-install.sh -n <ns> --registry <REPO>
#
# Usage:
#   podman login quay.io            # (or docker login)
#   ./build-push.sh -r quay.io/<you> [--tool podman|docker] [--tag TAG]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"

REPO=""; TOOL=""; TAG="latest"; PLATFORM="linux/amd64"   # OCP nodes are x86_64
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--registry) REPO="$2"; shift 2 ;;
    --tool) TOOL="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$REPO" ] || { echo "need -r <registry/namespace>, e.g. -r quay.io/hassanbadawy" >&2; exit 1; }
[ -n "$TOOL" ] || TOOL="$(command -v podman || command -v docker || true)"
[ -n "$TOOL" ] || { echo "neither podman nor docker found" >&2; exit 1; }
TOOL="$(basename "$TOOL")"

WEBUI="$REPO/smart-voice-assistant:$TAG"
TTS="$REPO/supertonic:$TAG"

echo "▶ Building web UI ($PLATFORM) → $WEBUI"
$TOOL build --platform "$PLATFORM" -t "$WEBUI" -f "$ROOT/Dockerfile" "$ROOT"
echo "▶ Building Supertonic ($PLATFORM) → $TTS"
$TOOL build --platform "$PLATFORM" -t "$TTS" -f "$ROOT/supertonic/Dockerfile" "$ROOT/supertonic"

echo "▶ Pushing"
$TOOL push "$WEBUI"
$TOOL push "$TTS"

echo ""
echo "✅ Pushed:"
echo "   $WEBUI"
echo "   $TTS"
echo ""
echo "Deploy with:  ./full-install.sh -n <namespace> --registry $REPO"
echo "(If the repos are PRIVATE, the installer creates a pull secret from your"
echo " local $TOOL login automatically.)"
