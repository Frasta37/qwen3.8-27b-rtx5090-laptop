#!/bin/bash
# One-shot: restart the server (DFlash2, context fitted to free VRAM by ensure-ninfer.sh),
# then report the process, VRAM and a test completion.
LOG=/tmp/ninfer.log
URL=http://127.0.0.1:18080

stop_server() {
  pkill -x '(ninfer|infernix)-serve' 2>/dev/null
  # Wait for the old process to exit so its VRAM is free before the new startup budget check.
  for _ in $(seq 1 30); do
    pgrep -x '(ninfer|infernix)-serve' >/dev/null || return 0
    sleep 1
  done
  # Infernix wants two Ctrl+C-style signals; after 30 s force it.
  pkill -9 -x '(ninfer|infernix)-serve' 2>/dev/null; sleep 3
  pgrep -x '(ninfer|infernix)-serve' >/dev/null || return 0
  echo "old server did not exit"; return 1
}

# Something else answering on the port would make ensure-ninfer.sh skip the start.
port_free() {
  if curl -sf "$URL/v1/models" >/dev/null 2>&1; then
    echo "port 18080 still answers after stopping the server: another process owns it"; return 1
  fi
}

stop_server && port_free || exit 1
echo "=== starting (ensure-ninfer.sh) ==="
~/ensure-ninfer.sh || exit 1
echo "=== process ==="
pgrep -ax '(ninfer|infernix)-serve' | head -3
echo "=== VRAM (MiB: used free total) ==="
nvidia-smi --query-gpu=memory.used,memory.free,memory.total --format=csv,noheader,nounits
echo "=== test completion ==="
curl -s "$URL/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":24,"temperature":0,"enable_thinking":false}' | head -c 500
echo
echo "=== log tail ==="
tail -n 8 "$LOG"
