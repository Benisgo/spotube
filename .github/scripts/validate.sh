#!/bin/bash
# Validate the Spotube codebase after changes.
# Run this after editing freezed models, Drift tables, or routes.
# Usage: .github/scripts/validate.sh

set -e

echo "=== Step 1: Code generation ==="
fvm dart run build_runner build --delete-conflicting-outputs
echo "✅ Code generation complete"

echo ""
echo "=== Step 2: Static analysis ==="
fvm flutter analyze
echo "✅ Analysis complete"

echo ""
echo "=== Step 3: Unit tests ==="
fvm flutter test
echo "✅ Tests passed"

echo ""
echo "=== All checks passed ==="
