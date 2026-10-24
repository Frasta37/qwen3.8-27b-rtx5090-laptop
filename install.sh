#!/bin/bash
# Copies the scripts into your home directory (run from the repo folder inside WSL/Ubuntu).
set -e
cd "$(dirname "$0")/scripts"
for f in *.sh; do sed 's/\r$//' "$f" > "$HOME/$f"; chmod +x "$HOME/$f"; done
if [ ! -f "$HOME/.local-llm.conf" ]; then
  sed 's/\r$//' local-llm.conf.example > "$HOME/.local-llm.conf"
  echo "created ~/.local-llm.conf - edit it with your paths before starting"
fi
echo "installed: $(ls *.sh | tr '\n' ' ')"
