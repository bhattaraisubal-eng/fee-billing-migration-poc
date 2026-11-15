#!/usr/bin/env bash
# Build everything from source and prove parity. No dependencies beyond Python 3.
set -euo pipefail
cd "$(dirname "$0")"

echo "### 1/5  regenerate the source extracts"
python3 tools/generate_data.py

echo
echo "### 2/5  reproduce the legacy Alteryx run"
python3 tools/run_legacy_workflow.py

echo
echo "### 3/5  build the target and reconcile"
python3 tools/build_target.py

echo
echo "### 4/5  independent arithmetic and control tests"
python3 testing/test_fee_math.py

echo
echo "### 5/5  Fabric T-SQL executed against the verified build"
if python3 -c "import sqlglot, duckdb" 2>/dev/null; then
    python3 tools/verify_fabric_sql.py 2>/dev/null | sed -n '/3. COMPARE/,$p'
else
    echo "skipped: pip install sqlglot duckdb to run it"
fi

echo
echo "### workflow inventory"
python3 tools/yxmd_inventory.py legacy/FeeBilling_Quarterly_v7_FINAL.yxmd \
    --csv delivery/workflow_backlog.csv
