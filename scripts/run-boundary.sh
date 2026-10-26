#!/usr/bin/env bash
#
# run-boundary.sh — write a "RUN TWO -- DEFENDED" banner into the collector's log, so
# anything below it belongs to run two. `make defend` runs it first, and ./4-rerun checks
# that nothing appears below it. If the collector does not answer, it only warns.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_attacker_ips
require_set COLLECTOR_PORT

STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
BAR="################################################################"

# The banner.
read -r -d '' BOUNDARY <<EOF || true
${BAR}
RUN TWO -- DEFENDED (controls now enforcing) -- ${STAMP}
Collector should show NOTHING below this line.
An empty collector here == the exfiltration was blocked.
${BAR}
EOF

# Print the banner here too. Falco alerts after its timestamp belong to run two.
printf '>> run-boundary: marking the run-1/run-2 boundary at %s\n' "$STAMP"
printf '%s\n' "$BOUNDARY"
printf '>> run-boundary: Falco alerts after %s belong to RUN TWO.\n' "$STAMP"

# Post the banner, with a time limit.
if curl -fsS --connect-timeout 3 --max-time 5 \
      -X POST "http://${COLLECTOR_IP}:${COLLECTOR_PORT}/" \
      --data-binary "$BOUNDARY" >/dev/null 2>&1; then
  printf '>> run-boundary: boundary marker written to the collector log.\n'
else
  printf '>> run-boundary: WARNING could not reach the collector at %s:%s — stdout banner stands; continuing.\n' \
    "$COLLECTOR_IP" "$COLLECTOR_PORT" >&2
fi
