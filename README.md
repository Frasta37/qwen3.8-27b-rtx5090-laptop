# Qwen3.8-27B on a 24 GB RTX 5090 Laptop (WSL2) with DFlash2

Scripts and measurements for running the
[wallawalla47/Qwen3.8-27B-Quasar-NVFP4-NInferV3](https://huggingface.co/wallawalla47/Qwen3.8-27B-Quasar-NVFP4-NInferV3)
model with [Infernix](https://github.com/Wallawalla47/Infernix) or
[NInfer](https://github.com/Neroued/ninfer) on a **laptop RTX 5090 (24 GB)**, as the backend for
[opencode](https://opencode.ai). Everything published for these engines assumes the 32 GB
desktop card; this documents what fits in 24 GB and how to keep it running without babysitting.

Tested on one machine only: Acer Predator 16, RTX 5090 Laptop GPU (24 GB), Windows 11 +
WSL2 Ubuntu, NVIDIA driver 617.42, CUDA 13.4, GCC 15.2, CMake 4.2.3, Infernix build
`windows-2026.10.18-59-gbe0d06e6` (commit `be0d06e6`), NInfer from a `ninfer-rtx5090-mobile`
fork. The model file is 17.7 GiB of weights on the GPU with vision loaded. Numbers below were
measured on 2026-10-24; your results will differ.

## Results

**What fits in 24 GB** (DFlash2 with 7 drafts, `--vision`, int8 KV, one request at a time,
no `--lm-head-draft`, default prefill chunk, desktop on the integrated GPU):

| Engine | Startup headroom | `--max-context` | Result |
|---|---|---:|---|
| NInfer | 1 GiB (fixed) | 65,536 | starts |
| NInfer | 1 GiB (fixed) | 81,920 | refused, 0.38 GiB short |
| Infernix | 512 MiB (`--vram-headroom-mib 512`) | 81,920 | starts; `--kv-capacity auto` sized the KV pool at 86,848 tokens |

With the Windows desktop on the NVIDIA GPU (Desktop Window Manager held ~1.5 GB) NInfer only
started DFlash2 + vision at 49,152 tokens. Switching the laptop to Optimus/Hybrid mode in
PredatorSense moved the desktop to the integrated GPU and freed that memory.

**Speed** (decode tok/s; acceptance = share of drafted tokens the model kept):

| Workload | NInfer MTP3 | NInfer DFlash2 | Infernix DFlash2 |
|---|---:|---:|---:|
| Short code answer (30-token prompt, 300 tokens out, greedy, no thinking) | – | 190 (76 %) | 163 (75 %) |
| Real opencode work, average over requests | ~82 | ~106 | ~116 |
| Long opencode request (5.6K prompt, 7.9K out, thinking) | – | 113 (45 %) | 118 (51 %) |
| Time to first token, follow-up turn on a 13.6K prompt | – | 0.2–0.4 s | 0.04 s (99.8 % cache) |
| Long session, 37–68K tokens of context, thinking on (n-gram on) | – | – | 65–96 typical; 200–280 on copy rounds |

Speed tracks the acceptance rate almost one to one, and acceptance depends on the content:
code and English prose accept well, free-form prose in other languages much less. The NInfer
MTP3 figure is from earlier everyday use, not a controlled comparison.

**Infernix with `--draft-tokens auto --ngram-draft-tokens auto`** (the author's recommended
setting; the engine picks the draft window, and copies text already in the context, such as code
being edited): the same short test went from 163 to 199 tok/s, and in an opencode editing
session at 51–68K tokens of context, requests that reproduced existing code ran at 222–279 tok/s
while the rest stayed at the usual 65–140 tok/s. KV room dropped from 86,848 to 82,752 tokens.

Infernix is slower on the short test with fixed 7 drafts because it replaced a lower-precision shortcut NInfer
uses while verifying drafts (see its README, "Defaults elsewhere that Infernix rejected"); in
real work with long prompts its faster prefill and better prefix cache more than make up for it.

## What the scripts do

- `ensure-ninfer.sh`: starts the server once (no-op if it is up), always with DFlash2. If the
  engine refuses to start for lack of VRAM, it reads the shortfall from the engine's error
  message, lowers `--max-context` just enough (plus a 128 MiB margin) and retries. It then
  writes the context in use into your opencode config(s) so opencode's compaction matches the
  server. Works with Infernix (default) and NInfer (`NINFER_ENGINE=ninfer`).
- `restart-ninfer-verify.sh`: stops the server, waits for its VRAM to be released, starts it
  again, and prints the process, VRAM and a test completion.
- `start-ninfer.sh`: `restart-ninfer-verify.sh` with a one-screen summary (optionally stops
  ComfyUI first).
- `stop-ninfer.sh`: stops the server by exact process name.
- `ninfer-stats.sh [N]`: per-request decode speed and draft acceptance from the last N
  requests in the log, with a time-weighted total.
- `ninfer-live.sh`, `ninfer-stream.sh`, `NInfer-ctl.ps1`, `NInfer-Control.bat`: a live control
  panel (PowerShell window: start/stop, VRAM, tokens per second, last requests, log tail).
- `opencode-launcher.bat`: starts the server if needed, waits for it, then opens opencode in
  a project folder.

Read the scripts before running them; `start-ninfer.sh` kills a ComfyUI process by name.

## Setup

1. Build Infernix (and/or NInfer) in WSL2 Ubuntu as its README says. With CUDA at
   `/usr/local/cuda`: `cmake --preset release -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc && cmake --build build -j`.
   Keep the `.ninfer` model file on the Linux filesystem, not under `/mnt/c`.
2. In Ubuntu: `git clone <this repo> && cd <this repo> && ./install.sh`, then edit
   `~/.local-llm.conf` (model path, engine directories, your opencode config path).
3. In opencode, point a provider at `http://127.0.0.1:18080/v1` (see `opencode.jsonc.example`).
   The `"limit": { "context": N, ... }` line must be on one line in that form; the scripts rewrite N.
4. Start with `~/start-ninfer.sh`. For the panel, copy `NInfer-ctl.ps1` and
   `NInfer-Control.bat` into one folder on Windows and run `NInfer-Control.bat`.
5. If the GPU also drives your screen, switch the laptop to Optimus/Hybrid mode (PredatorSense,
   Armoury Crate, Vantage, …; one reboot). Games still run on the NVIDIA GPU. Move apps that
   need no GPU (Electron apps, browsers) to "Power saving" in Windows Settings > Display >
   Graphics so they do not take VRAM at startup.

Flags used (`ensure-ninfer.sh`): `--max-concurrency 1 --max-context 81920 --kv-capacity auto
--kv-dtype int8 --vision --default-thinking-budget 4096 --spec dflash2 --draft-tokens auto
--ngram-draft-tokens auto`, plus `--vram-headroom-mib 512 --tolerant-tool-calls` on Infernix
(`--draft-tokens 7` on NInfer, which has no `auto` and no n-gram drafting). `--lm-head-draft` (~0.35 GiB)
and `--prefill-chunk 4096` were dropped to fit. Output quality is not affected by DFlash2:
the full model verifies every drafted token.

## Notes

- The per-token KV cost used for the context fitting is 32,816 B (int8), NInfer's own figure
  for this model. For a different KV format or model, change it in `smaller_context`.
- Infernix needs two Ctrl+C to stop when run in the foreground; the scripts handle it.
- opencode compacts when the context reaches `limit.context - compaction.buffer` (the output
  limit is not subtracted), so keep `buffer` above `limit.output`; the example uses 20,000.
- Pinning host RAM: Infernix pins 8 GiB for its prefix cache by default (`--host-context-mib`).

License: MIT.
