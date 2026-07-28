# Validate the Spotube codebase after changes.
# Run this after editing freezed models, Drift tables, or routes.
# Usage: .github\scripts\validate.ps1

$ErrorActionPreference = "Stop"

Write-Host "=== Step 1: Code generation ==="
fvm dart run build_runner build --delete-conflicting-outputs
Write-Host "=== Code generation complete ==="

Write-Host "`n=== Step 2: Static analysis ==="
fvm flutter analyze
Write-Host "=== Analysis complete ==="

Write-Host "`n=== Step 3: Unit tests ==="
fvm flutter test
Write-Host "=== Tests passed ==="

Write-Host "`n=== All checks passed ==="
