#!/bin/bash
# Per-request speed and draft acceptance from the current server's log. Usage: ninfer-stats.sh [N requests]
grep 'done |' /tmp/ninfer.log | tail -n "${1:-20}" | awk -F'|' '
{ p = o = r = acc = dr = 0; be = ""
  for (i = 1; i <= NF; i++) {
    f = $i; gsub(",", "", f); split(f, a, " ")
    if (a[1] == "prompt") p = a[2]
    if (a[1] == "output") o = a[2]
    if (a[1] == "decode") r = a[2]
    if (a[2] == "accepted") { split(a[3], c, "/"); acc = c[1]; dr = c[2]; be = a[1] }
    if (a[1] == "mixed" && a[3] == "accepted") { split(a[4], c, "/"); acc = c[1]; dr = c[2]; be = "mixed" }
    if (a[1] == "ngram" && a[3] == "accepted") { split(a[2], c, "/"); ng += c[1]; ngd += c[2] }
  }
  if (r > 0 && o > 1) { T += (o - 1) / r; O += o - 1 }
  A += acc; D += dr; if (be != "") B = be
  printf "prompt %7d  output %6d  decode %6.1f tok/s  %s %s\n", p, o, r, be, (dr ? sprintf("%.0f%%", 100 * acc / dr) : "-")
}
END { if (T) printf "TOTAL: %d tokens decoded at %.1f tok/s (time-weighted) | %s accepted %.1f%%%s\n", O, O / T, B, (D ? 100 * A / D : 0), (ngd ? sprintf(" | ngram copies %d/%d", ng, ngd) : "") }'
