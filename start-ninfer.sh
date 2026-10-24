#!/bin/bash
# (Re)start the server through the shared scripts: the flags live only in ~/ensure-ninfer.sh
# (DFlash2, context fitted to free VRAM). Optionally stops ComfyUI first to free its VRAM.
# Full start report: /tmp/ninfer-start.log
pkill -f "[m]ain.py --listen 127.0.0.1 --port 8188"   # ComfyUI; remove if you do not use it
sleep 3
~/restart-ninfer-verify.sh > /tmp/ninfer-start.log 2>&1
status=$?
grep -E 'starting \(pid|not enough|does not fit|UP after|opencode context|FAILED|another process' /tmp/ninfer-start.log
exit $status
