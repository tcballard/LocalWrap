#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ITERATIONS="${LOCALWRAP_SOAK_ITERATIONS:-2}"
[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || { echo "LOCALWRAP_SOAK_ITERATIONS must be positive" >&2; exit 2; }

xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
started="$(date +%s)"
for ((iteration = 1; iteration <= ITERATIONS; iteration++)); do
  echo "Native soak iteration $iteration/$ITERATIONS"
  xcodebuild -quiet -project "$ROOT/LocalWrap.xcodeproj" -scheme LocalWrapMac \
    -destination 'platform=macOS' -derivedDataPath "$ROOT/.build/LocalWrapMac-Soak" test \
    -only-testing:LocalWrapMacTests/RuntimeServiceTests/testBundledSampleReachesReadyAndLeavesNoProcessGroup \
    -only-testing:LocalWrapMacTests/WorkspaceServicesTests/testRealDependencyStackStartsInOrderAndCleansBothProcessGroups
done
echo "Native soak passed: $ITERATIONS iterations in $(($(date +%s) - started))s"
