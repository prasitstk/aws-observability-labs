#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ERRORS=0

echo "=== Terraform Validation Suite ==="
echo ""

for dir in $(find shared/modules labs -type f -name "*.tf" -exec dirname {} \; | sort -u); do
  echo -n "Validating ${dir}... "

  if ! terraform -chdir="$dir" init -backend=false -input=false > /dev/null 2>&1; then
    echo -e "${RED}INIT FAILED${NC}"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if ! terraform -chdir="$dir" fmt -check > /dev/null 2>&1; then
    echo -e "${RED}FMT FAILED${NC}"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if ! terraform -chdir="$dir" validate > /dev/null 2>&1; then
    echo -e "${RED}VALIDATE FAILED${NC}"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  echo -e "${GREEN}OK${NC}"
done

echo ""
if [ $ERRORS -gt 0 ]; then
  echo -e "${RED}${ERRORS} error(s) found${NC}"
  exit 1
else
  echo -e "${GREEN}All checks passed${NC}"
fi
