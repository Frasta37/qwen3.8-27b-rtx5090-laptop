#!/bin/bash
# Stop the server if it is running, and clear its PID file. Safe to run when nothing is up.
pkill -x '(ninfer|infernix)-serve' 2>/dev/null
sleep 1
pkill -9 -x '(ninfer|infernix)-serve' 2>/dev/null
rm -f "$HOME/.ninfer.pid"
echo "server stopped."
