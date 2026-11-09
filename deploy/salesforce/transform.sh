#!/usr/bin/env bash
# Build sf.people / sf.threads / sf.parts from the raw export tables loaded by load_staging.sh.
#   deploy/salesforce/transform.sh            # all stages
#   deploy/salesforce/transform.sh 03 04      # re-run selected stages
set -euo pipefail
cd "$(dirname "$0")"
stages=("$@"); [ ${#stages[@]} -eq 0 ] && stages=(01 02 03 04)
for s in "${stages[@]}"; do
  f=$(ls sql/"${s}"_*.sql)
  echo "== $f  $(date +%H:%M:%S)"
  docker exec -i -e PGOPTIONS='-c client_min_messages=warning' sf-staging psql -v ON_ERROR_STOP=1 -U sf -d sf < "$f"
done
echo "transform complete $(date +%H:%M:%S)"
