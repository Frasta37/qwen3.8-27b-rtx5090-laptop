#!/bin/bash
# Ensure the local LLM server (Infernix or NInfer) is running exactly once, with DFlash2.
# If a healthy instance is already serving on the port, do nothing.
# If DFlash2 does not fit in free VRAM (e.g. another app holds some), retry with a smaller
# --max-context; then write the context in use into opencode's config(s).
# Settings: ~/.local-llm.conf (see local-llm.conf.example); environment variables override it.
[ -f "$HOME/.local-llm.conf" ] && . "$HOME/.local-llm.conf"
PORT=${NINFER_PORT:-18080}
PIDFILE="$HOME/.ninfer.pid"
LOG=${NINFER_LOG:-/tmp/ninfer.log}
SPEC_ARGS=${NINFER_SPEC:-"--spec dflash2 --draft-tokens auto --ngram-draft-tokens auto"}
# Context ceiling; int8 KV costs ~32 KiB/token (81920 -> ~2.5 GiB of VRAM).
MAX_CONTEXT=${NINFER_MAX_CONTEXT:-81920}
MIN_CONTEXT=${NINFER_MIN_CONTEXT:-24576}
MODEL=${NINFER_MODEL:-"$HOME/models/qwen3_8_27b_nvfp4.ninfer"}
read -r -a OPENCODE_CONFIGS <<< "${NINFER_OPENCODE_CONFIGS:-$HOME/.config/opencode/opencode.json}"
# Engine: infernix (default) or ninfer; both read the same .ninfer file.
case "${NINFER_ENGINE:-infernix}" in
  infernix)
    ENGINE_DIR=${INFERNIX_DIR:-$HOME/infernix}; SERVER=./build/apps/infernix-serve
    # 512 MiB of startup headroom instead of NInfer's fixed 1 GiB. Keep it above 0 if the
    # GPU also drives the display.
    ENGINE_ARGS=(--vram-headroom-mib "${NINFER_HEADROOM_MIB:-512}" --tolerant-tool-calls) ;;
  ninfer)
    ENGINE_DIR=${NINFER_DIR:-$HOME/ninfer}; SERVER=./build/apps/ninfer-serve
    ENGINE_ARGS=()
    # NInfer has no automatic draft window and no n-gram drafting.
    [ -n "$NINFER_SPEC" ] || SPEC_ARGS="--spec dflash2 --draft-tokens 7" ;;
  *) echo "unknown NINFER_ENGINE: $NINFER_ENGINE"; exit 1 ;;
esac

is_alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

# Copies the running server's --max-context into each opencode config's "limit" line.
sync_opencode() {
  local ctx f
  ctx=$(pgrep -ax '(ninfer|infernix)-serve' | grep -oE -- '--max-context [0-9]+' | head -n 1 | cut -d' ' -f2)
  [ -n "$ctx" ] || return 0
  for f in "${OPENCODE_CONFIGS[@]}"; do
    [ -f "$f" ] || { echo "opencode config not found, skipped: $f"; continue; }
    grep -qE "\"limit\": \{ \"context\": $ctx," "$f" && continue
    sed -i -E "s/(\"limit\": \{ \"context\": )[0-9]+/\1$ctx/" "$f"
    if grep -qE "\"limit\": \{ \"context\": $ctx," "$f"; then
      echo "opencode context set to $ctx in $f"
    else
      echo "WARNING: no one-line \"limit\": { \"context\": N, ... } in $f; set its context to $ctx by hand"
    fi
  done
}

# 1) Trust the recorded PID first
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if is_alive "$pid"; then
    sync_opencode
    exit 0   # already running -> no-op
  fi
fi

# 2) Fallback: check if something is listening on the port
if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
  echo "server already serving on :$PORT"
  sync_opencode
  exit 0
fi

# 3) Start detached, recording its PID.
# --lm-head-draft (~0.35 GiB proposal head) and --prefill-chunk 4096 (default 1024) are left out
# to fit DFlash2 and --vision in 24 GB.
launch() {
  cd "$ENGINE_DIR" || exit 1
  nohup "$SERVER" \
    "$MODEL" \
    --host 127.0.0.1 \
    --port "$PORT" \
    --max-concurrency 1 \
    --default-max-tokens 8192 \
    --max-context "$1" \
    --kv-capacity auto \
    --kv-dtype int8 \
    --vision \
    --default-thinking-budget 4096 \
    "${ENGINE_ARGS[@]}" \
    $SPEC_ARGS >>"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "${SERVER##*/} starting (pid $(cat "$PIDFILE")): $SPEC_ARGS, max-context $1"
}

# 0 = serving, 1 = process exited during startup, 2 = still starting after 5 minutes.
wait_up() {
  local pid i
  pid=$(cat "$PIDFILE" 2>/dev/null)
  for i in $(seq 1 100); do
    if curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then echo "UP after ~$((i*3))s"; return 0; fi
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 3
  done
  return 2
}

# Context that fits after a VRAM FATAL: the shortfall (+128 MiB margin) at ~32 KiB/token,
# rounded up to whole 1024-token steps. Prints nothing when the failure was not about VRAM.
# NInfer prints "requires MIN bytes in addition to HEADROOM bytes ..., but only AVAIL";
# Infernix prints "requires TOTAL bytes total (MIN ... + HEADROOM ...), but only AVAIL".
smaller_context() {
  local nums need
  nums=$(tail -n 5 "$LOG" | grep 'minimum Engine runtime reservation' | grep -oE '[0-9]{7,}')
  set -- $nums
  [ $# -ge 3 ] || return 0
  if [ $# -ge 4 ]; then need=$1; else need=$(($1 + $2)); fi
  awk -v n="$need" -v a="${!#}" -v ctx="$CTX" 'BEGIN {
    s = n - a + 128 * 2^20
    cut = int((s / 32816 + 1023) / 1024) * 1024
    printf "%d\n", ctx - cut }'
}

: > "$LOG"
CTX=$MAX_CONTEXT
while :; do
  launch "$CTX"
  wait_up
  status=$?
  [ $status -eq 1 ] || break
  next=$(smaller_context)
  if [ -z "$next" ] || [ "$next" -lt "$MIN_CONTEXT" ]; then
    echo "DFlash2 does not fit even at $MIN_CONTEXT tokens of context (free some VRAM and retry)"
    break
  fi
  echo "not enough free VRAM for $CTX tokens of context: retrying with $next"
  CTX=$next
done
if [ $status -eq 0 ]; then
  sync_opencode
else
  echo "SERVER FAILED TO COME UP"; tail -n 3 "$LOG"
fi
exit $status
