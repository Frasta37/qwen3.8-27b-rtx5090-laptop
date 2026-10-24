@echo off
title OpenCode
rem Start the local LLM server if needed and wait for it: ensure-ninfer.sh fits the context
rem to the free VRAM and writes it into opencode config before opencode reads it.
wsl -d Ubuntu -- bash -lc "~/ensure-ninfer.sh"
if errorlevel 1 (
  echo The server did not start - see the messages above.
  pause
  exit /b 1
)
rem Your project folder:
cd /d C:\your_project
opencode.cmd
