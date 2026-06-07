#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=live-demo-lib.sh
source "$SCRIPT_DIR/live-demo-lib.sh"

main() {
  echo "Running live Reactive settlement demo resume preflight..."
  preflight_from_rfs

  if [ "$BROADCAST" != "true" ]; then
    fail "live-demo-from-rfs requires BROADCAST=true. This harness resumes an in-flight live demo."
  fi

  local current_queue
  current_queue="$(read_queue "$LCC_OUT" "$RECIPIENT")"
  if [ -z "${QUEUED_AFTER_SWAP:-}" ]; then
    QUEUED_AFTER_SWAP="$current_queue"
    echo "QUEUED_AFTER_SWAP not set; using current settleQueue baseline: $QUEUED_AFTER_SWAP"
  fi
  dec_gt "$QUEUED_AFTER_SWAP" 0 || fail "settleQueue(lccOut, recipient) must be > 0. Confirm LCC_OUT and RECIPIENT from the failed live-demo run."

  WF_RESUME="PASS"
  export COMMIT_ID POSITION_INDEX LCC_OUT QUEUED_AFTER_SWAP

  if dec_lt "$current_queue" "$QUEUED_AFTER_SWAP"; then
    echo "Queue already decreased below queuedAfterSwap baseline; skipping maker settlement and queue wait."
    QUEUED_FINAL="$current_queue"
    WF_SETTLE="SKIP"
    WF_QUEUE_DECREASE="PASS"
    run_close_if_enabled
    print_summary_from_rfs "PASS"
    return 0
  fi

  run_settle_until_rfs_closed
  WF_SETTLE="PASS"

  current_queue="$(read_queue "$LCC_OUT" "$RECIPIENT")"
  if dec_lt "$current_queue" "$QUEUED_AFTER_SWAP"; then
    QUEUED_FINAL="$current_queue"
    WF_QUEUE_DECREASE="PASS"
  elif ! wait_until "protocol settleQueue decrease after maker settlement" queue_decreased; then
    QUEUED_FINAL="$(read_queue "$LCC_OUT" "$RECIPIENT")"
    WF_QUEUE_DECREASE="FAIL"
    print_summary_from_rfs "FAIL"
    fail "Settlement queue did not decrease. Check BatchProcessSettlement events and HubRSC retry/terminal state."
  else
    QUEUED_FINAL="$(read_queue "$LCC_OUT" "$RECIPIENT")"
    WF_QUEUE_DECREASE="PASS"
  fi

  run_close_if_enabled
  print_summary_from_rfs "PASS"
}

main "$@"