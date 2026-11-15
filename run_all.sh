#!/usr/bin/env bash
# Build everything from source and prove parity. No dependencies beyond Python 3.
set -euo pipefail
cd "$(dirname "$0")"

echo "### 1/4  regenerate the source extracts"
python3 tools/generate_data.py

echo
echo "### 2/4  reproduce the legacy Alteryx run"
python3 tools/run_legacy_workflow.py

echo
echo "### 3/4  build the target and reconcile"
python3 tools/build_target.py

echo
echo "### 4/4  independent arithmetic and control tests"
python3 testing/test_fee_math.py

echo
echo "### workflow inventory"
python3 tools/yxmd_inventory.py legacy/FeeBilling_Quarterly_v7_FINAL.yxmd \
    --csv delivery/workflow_backlog.csv
