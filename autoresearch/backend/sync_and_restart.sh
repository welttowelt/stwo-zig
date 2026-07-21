#!/bin/sh
# Serving-checkout sync for the production backend (stwo-zig-sync.service).
#
# A bare `git pull` is not a deployment: on July 20 the ledger's first v2 row
# was pulled under a backend process still importing the pre-v2 parser, and
# /v1/frontier served 500s until an unrelated restart (issue #22). This
# fast-forwards the checkout, restarts the backend only when served code
# changed, and smoke-checks the frontier endpoints so a bad restart fails
# the unit loudly instead of serving errors quietly.
#
# Requires a sudoers rule for exactly the restart:
#   stwo ALL=(root) NOPASSWD: /usr/bin/systemctl restart stwo-perf-backend.service
set -eu

REPO="${1:-/opt/stwo-zig}"

before=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" pull --ff-only --quiet
after=$(git -C "$REPO" rev-parse HEAD)
[ "$before" = "$after" ] && exit 0

if git -C "$REPO" diff --name-only "$before" "$after" -- \
     autoresearch/backend/ autoresearch/cli/stwo_perf/ | grep -q .; then
  sudo /usr/bin/systemctl restart stwo-perf-backend.service
  sleep 2
  for cell in core_cpu/deep core_metal/deep; do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:8787/v1/frontier/$cell")
    if [ "$code" != "200" ]; then
      echo "smoke check failed after restart: /v1/frontier/$cell -> $code" >&2
      exit 1
    fi
  done
  echo "backend restarted for $before..$after; frontier endpoints healthy"
fi
