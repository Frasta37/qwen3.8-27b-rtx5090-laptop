#!/bin/bash
# One-shot live snapshot of the server + GPU.
# Emits machine-parseable KEY=value lines consumed by NInfer-ctl.ps1.
PORT_N=18080
LOG=/tmp/ninfer.log
NOW=$(date +%s)

# ---- process state ----
NP=$(pgrep -x '(ninfer|infernix)-serve' | head -1)
if [ -n "$NP" ]; then
  UP=$(ps -o etime=   -p "$NP" 2>/dev/null | tr -d ' ')
  RSS_KB=$(ps -o rss= -p "$NP" 2>/dev/null | tr -d ' ')
  RSS_GB=$(awk -v k="${RSS_KB:-0}" 'BEGIN{printf "%.1f", k/1048576}')
  CPU=$(ps -o %cpu=  -p "$NP" 2>/dev/null | tr -d ' ')
  echo "STATE=running|pid=$NP|up=${UP:-?}|rss_gb=$RSS_GB|cpu=${CPU:-0}"
else
  echo "STATE=stopped|pid=none|up=-|rss_gb=0|cpu=0"
fi

# ---- GPU (VRAM / util / temp / power) ----
nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
  --format=csv,noheader,nounits 2>/dev/null | head -1 | awk -F', ' '
{
  mu=$3/1024; mt=$4/1024;
  printf "GPU=name=%s|util=%s|mem_gb=%.1f|mem_total_gb=%.1f|temp=%s|power=%s\n", $1, $2, mu, mt, $5, $6
}' 2>/dev/null || echo "GPU=name=unknown|util=0|mem_gb=0.0|mem_total_gb=0.0|temp=0|power=0"

# ---- comfyui ----
if ss -ltn 2>/dev/null | grep -q ":8188 "; then echo "CUI=running"; else echo "CUI=stopped"; fi

# ---- live activity (from log) ----
S=""; AGO=0; RUN=0
LATEST=$(grep -E "INFO +(throughput|req#)" "$LOG" 2>/dev/null | tail -1)
if [ -n "$LATEST" ]; then
  TS=$(printf '%s' "$LATEST" | awk '{print $1" "$2}' | cut -c1-19)
  EP=$(date -d "$TS" +%s 2>/dev/null)
  if [ -n "$EP" ]; then
    AGO=$((NOW-EP)); [ "$AGO" -lt 0 ] && AGO=0
    [ "$AGO" -le 6 ] && S=LIVE || S=IDLE
    RUN=$(grep -E "throughput" "$LOG" 2>/dev/null | tail -1 | sed -n 's/.*running \([0-9]\+\).*/\1/p')
  fi
fi
[ -z "$S" ] && S=off
echo "LIVE=$S|ago=$AGO|running=${RUN:-0}"

# ---- token panel (throughput / capacity / session totals) ----
# latest throughput line: decode tok/s, running, prefill tokens
TP=$(grep -E "INFO +throughput" "$LOG" 2>/dev/null | tail -1)
DTS=$(printf '%s' "$TP" | sed -n 's/.*decode \([0-9.]*\) tok\/s.*/\1/p')
RUN=$(printf '%s' "$TP" | sed -n 's/.*running \([0-9]\+\).*/\1/p')
PFT=$(printf '%s' "$TP" | sed -n 's/.*prefill [0-9.]*[km]\? tok\/s (\([0-9,]*\) tok).*/\1/p')
# latest capacity line: KV tokens + type (NInfer: "KV N tokens, int8"; Infernix: "N tokens of context ... (int8 KV)")
CAP=$(grep -E "capacity" "$LOG" 2>/dev/null | tail -1)
KVTOK=$(printf '%s' "$CAP" | sed -n -E 's/.*(KV |\| )([0-9,]+) tokens.*/\2/p')
KVTYP=$(printf '%s' "$CAP" | grep -oE 'int8|bf16|fp8|nvfp4|k8v4|vq2|k4v2' | head -1)
# session totals: sum prompt + output over EVERY "req#N done" in the whole log
SEHP=$(grep -E "req#[0-9]+ done" "$LOG" 2>/dev/null | sed -n 's/.*prompt \([0-9,]*\).*/\1/p' | tr -d ',' | awk '{s+=$1} END{print s+0}')
SESO=$(grep -E "req#[0-9]+ done" "$LOG" 2>/dev/null | sed -n 's/.*output \([0-9,]*\).*/\1/p' | tr -d ',' | awk '{s+=$1} END{print s+0}')
echo "TOK=decode=${DTS:-0}|running=${RUN:-0}|prefill_tok=${PFT:-0}|kv=${KVTOK:-0}|kvtype=${KVTYP:-}|seshp=${SEHP:-0}|sesout=${SESO:-0}"
# most recent completed request
DONE_LINE=$(grep -E "req#[0-9]+ done" "$LOG" 2>/dev/null | tail -1)
DL_ID=$(printf '%s' "$DONE_LINE" | sed -n 's/^.*req#\([0-9]\+\).*/\1/p')
DL_PR=$(printf '%s' "$DONE_LINE" | sed -n 's/.*prompt \([0-9,]*\).*/\1/p')
DL_OU=$(printf '%s' "$DONE_LINE" | sed -n 's/.*output \([0-9,]*\).*/\1/p')
DL_CA=$(printf '%s' "$DONE_LINE" | sed -n 's/.*cache [0-9,]* (\([0-9.]*\)%.*/\1/p')
echo "LAST=id=${DL_ID:-}|prompt=${DL_PR:-0}|output=${DL_OU:-0}|cache=${DL_CA:-0}"

# ---- recent log (prefix each line) ----
tail -n 16 "$LOG" 2>/dev/null | sed 's/^/LOG=/'
echo "DONE="
