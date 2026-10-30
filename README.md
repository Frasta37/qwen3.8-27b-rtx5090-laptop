# Qwen3.8-27B on a 24 GB RTX 5090 Laptop (WSL2) with DFlash2

Scripts and measurements for running the
[wallawalla47/Qwen3.8-27B-Quasar-NVFP4-NInferV3](https://huggingface.co/wallawalla47/Qwen3.8-27B-Quasar-NVFP4-NInferV3)
model with [Infernix](https://github.com/Wallawalla47/Infernix) or
[NInfer](https://github.com/Neroued/ninfer) on a **laptop RTX 5090 (24 GB)**, as the backend for
[opencode](https://opencode.ai). Everything published for these engines assumes the 32 GB
desktop card; this documents what fits in 24 GB and how to keep it running without babysitting.

Tested on one machine only: Acer Predator 16, RTX 5090 Laptop GPU (24 GB), Windows 11 +
WSL2 Ubuntu, NVIDIA driver 617.42, CUDA 13.4, GCC 15.2, CMake 4.2.3. Engines: Infernix
`be0d06e6` (2026-10-24) and `f97ce37d` (main on 2026-10-30, includes PR #50); NInfer from the
`ninfer-rtx5090-mobile` fork (`b53468fa`, synced with upstream through `e31bc99b`). The model
file is 17.7 GiB of weights on the GPU with vision loaded. Each number below names its build
and date; your results will differ.

## Results

**What fits in 24 GB** (DFlash2, `--vision`, int8 KV, one request at a time, no
`--lm-head-draft`, default prefill chunk, Windows desktop on the integrated GPU):

| Engine | Startup headroom | `--max-context` | Result |
|---|---|---:|---|
| NInfer | 1 GiB (fixed) | 65,536 | starts |
| NInfer | 1 GiB (fixed) | 81,920 | refused, 0.38 GiB short |
| Infernix | 512 MiB (`--vram-headroom-mib 512`) | 81,920 | starts |

Infernix's `--kv-capacity auto` sized its KV pool at 86,848 tokens with 7 fixed drafts (started
with `--max-context 65536`) and at 82,752 with `--draft-tokens auto --ngram-draft-tokens auto`
(started with 81,920). Infernix's documentation notes that wider verification rounds need extra
workspace and graph memory; the two starts also differed in `--max-context`.

With the Windows desktop on the NVIDIA GPU (Desktop Window Manager held ~1.5 GB), NInfer was
0.24 GiB short of DFlash2 + vision at 65,536 tokens and ran at 49,152. Switching the laptop to
Optimus/Hybrid mode in PredatorSense moved the desktop to the integrated GPU and freed that memory.

**Speed: controlled short test** (2026-10-30). The same greedy request on both engines with the
same flags, run alternately (Infernix, NInfer, Infernix, NInfer); each session had one warm-up
and 3 measured requests, and all six measured runs per engine were within 0.3 tok/s. Flags:
`--max-concurrency 1 --max-context 65536 --kv-capacity auto --kv-dtype int8 --vision
--default-thinking-budget 4096 --spec dflash2 --draft-tokens 7` (Infernix also
`--vram-headroom-mib 512 --tolerant-tool-calls`). Request: "Write a Python function that reads a
CSV file and returns the average of each numeric column.", `max_tokens` 400, temperature 0,
thinking off. The two `auto` rows are separate measurements of the same request on the normal
server (`--max-context 81920`, `--draft-tokens auto --ngram-draft-tokens auto`), not part of the
alternating runs.

| Engine (commit) | Decode tok/s | Output tokens | Accepted / drafted | Rounds | Time per round |
|---|---:|---:|---:|---:|---:|
| NInfer fork (`b53468fa`) | 196.0–196.3 | 297 | 250/329 (76.0 %) | 47 | 32.1 ms |
| Infernix main (`f97ce37d`, includes PR #50) | 178.2–178.4 | 299 | 250/343 (72.9 %) | 49 | 34.1 ms |
| Infernix `be0d06e6` (same command, 2026-10-24, average of 2 runs) | 163.1 | 299 | 251/336 (74.7 %) | 48 | 38.1 ms |
| Infernix main (`f97ce37d`), `--draft-tokens auto --ngram-draft-tokens auto` (2026-10-30, 2 runs) | 206.6–206.8 | 299 | 263/441–462 (57–60 %) | 36 | 40.0 ms |
| Infernix `be0d06e6`, `--draft-tokens auto --ngram-draft-tokens auto` (2026-10-24, one run) | 198.8 | 299 | 263/467 (56.3 %) | 36 | 41.6 ms |

Rounds = output − accepted (each round yields its accepted drafts plus one token from the full
model; with 7 fixed drafts this equals drafted / 7). Time per round = (output − 1) / decode rate /
rounds.

With 7 fixed drafts NInfer is about 10 % faster than Infernix on this reply. About 3.5 % of that
is acceptance: the engines' greedy outputs differ (297 vs 299 tokens) and Infernix's needs 2 more
rounds. The other ~6 % is time per round; its cause has not been isolated. Between `be0d06e6` and
`f97ce37d` (which includes PR #50), Infernix's time per round here fell from 38.1 to 34.1 ms; the
two builds were measured on different days, and other changes between them are included.

With its automatic draft window (`--draft-tokens auto --ngram-draft-tokens auto`, the default in
these scripts), current Infernix is about 5 % faster than NInfer at 7 drafts on this reply: 206.6–206.8
against 196.0–196.3 tok/s. It writes the same 299-token answer in 36 longer rounds (12–13 drafts
each) instead of 49 short ones. The older build gave identical counts in this mode at 198.8 tok/s,
so the newer build's rounds are about 4 % shorter (40.0 against 41.6 ms). The first request after a
server start was slower in both starts measured (197.5 and 186.6 tok/s) and wrote a slightly
different answer (280 and 286 tokens); the two runs in the table followed it. NInfer has no
automatic window. On a desktop RTX 5090 with the official artifact and upstream NInfer, the
Infernix author measured the two engines level at about 420 tok/s (7 drafts).

**Speed: everyday opencode use.** Not a controlled comparison: each column is a different set of
requests, the NInfer DFlash2 session ran before the switch to Optimus (desktop on the NVIDIA GPU),
and decode slows as the context grows. Infernix columns are build `be0d06e6`.

| | NInfer MTP3 | NInfer DFlash2, 7 drafts | Infernix DFlash2, 7 drafts | Infernix auto + n-gram |
|---|---:|---:|---:|---:|
| Requests (prompt sizes) | – | 5 (7–23K) | 4 (0.5–14K) | 20 (51–68K) |
| Decode tok/s, weighted by time | ~82* | 111 | 116 | 110 |
| Decode tok/s, per request | – | 79–128 | 83–118 | 65–279 |
| First token on a follow-up turn | – | – | 0.04 s at 13.6K (99.8 % cached) | 0.22–0.44 s at 38–41K (96–99 % cached) |

\* From the previous setup's own monitoring, not measured here.

Speed follows the acceptance rate closely, and acceptance depends on the content: code and
English prose accept well, free-form prose in other languages much less. The 222–279 tok/s
requests in the n-gram session were most likely copy-heavy (per-request copy counts were not
recorded): when the model reproduces text already in the context, such as an edit of existing code
or a file echoed from a tool result, n-gram drafting proposes up to 63 tokens at once and the full
model only verifies them.

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
