#!/bin/bash
# Continuous real-time feed for the control window.
# Emits complete, atomic lines to stdout:
#   H|<one-time header>
#   L|<raw log line>          (from tail -n 20 -f /tmp/ninfer.log)
#   STATUS|state=.. vram=a/b GB util=u% temp=tC   (every 5s)
LOG=/tmp/ninfer.log

gpu() {
  nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null | head -1 \
    | awk -F', ' '{printf "%.1f %.1f %d %d", $1/1024, $2/1024, $3, $4}'
}

emit_status() {
  local NP ST MU MT UT TP
  NP=$(pgrep -x '(ninfer|infernix)-serve' | head -1)
  ST=stopped; [ -n "$NP" ] && ST=running
  read -r MU MT UT TP < <(gpu)
  MU=${MU:-0}; MT=${MT:-0}; UT=${UT:-0}; TP=${TP:-0}
  printf 'STATUS|state=%s  vram=%s/%s GB  util=%s%%  temp=%sC\n' "$ST" "$MU" "$MT" "$UT" "$TP"
}

# one-time header
emit_status | sed 's/^STATUS|/H|NInfer live  |  /'
printf 'H|legend: green=request  yellow=activity  red=error  |  [Q]/Enter/Esc = quit\n'

# live tail: last 20 lines for context, then follows. -u = unbuffered (flush each line).
tail -n 20 -f "$LOG" 2>/dev/null | sed -u 's/^/L|/' &
TAILPID=$!

# periodic status every 5s
while true; do
  sleep 5
  emit_status
done &
STATUSPID=$!

trap 'kill $TAILPID $STATUSPID 2>/dev/null; exit 0' INT TERM EXIT
wait $TAILPID $STATUSPID
