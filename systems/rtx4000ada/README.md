# RTX 4000 Ada system image — llama.cpp serving notes

Serves **Qwen3.6-27B (Q4_K_M GGUF, multimodal)** as `qwen3.6-27b` via the `llama.container`
Quadlet, image `ghcr.io/ggml-org/llama.cpp:server-cuda`, on the RTX 4000 Ada (20 GB).
Ported from a reference docker-compose into the bootc Quadlet path (no compose), mirroring
the rtx3080ti system's approach. Decoding is accelerated with **MTP (Multi-Token
Prediction)** speculative decoding — see [MTP](#mtp-speculative-decoding) below.

## Model download (automatic — no manual step)

The weights are **not** baked into the image and you do **not** download them by hand.
`llama.container` uses llama.cpp's `-hf unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M`, which on first
start downloads the Q4_K_M GGUF (with speculative-decoding heads) **and** the matching
mmproj (vision projector) automatically from Hugging Face (~18 GB total). The download is
cached under `LLAMA_CACHE=/cache` → host `/var/lib/llama/cache`, so it happens once and
survives reboots/upgrades. The service is enabled by default; on first boot it fetches the
model, then serves the OpenAI-compatible API + `/metrics` on port 8000 (first start takes a
while — see `TimeoutStartSec`).

### Why this specific repo (20 GB VRAM budget)

Qwen3.6 is a **hybrid** architecture: most layers use linear attention with a tiny,
context-independent KV state, so on this card lowering context frees almost no VRAM. The
binding constraint is not KV but the sum of model + mmproj + the **MTP heads** + the
mmproj **image-encode scratch** (~0.7 GB allocated at runtime for vision). The MTP heads
consume the headroom that a full 65536 context + vision would need, so context is set to
**49152** (verified max on the target; 40960 for extra margin). The Q4_K_M file must be
**≤ ~17 GB**:

| Repo | Q4_K_M | Fits on 20 GB (with MTP + vision)? |
|---|---:|---|
| **unsloth/Qwen3.6-27B-MTP-GGUF** (current) | 17.1 GB | ✅ verified — 19714/20475 MiB at load, 19832 peak under stress |
| unsloth/Qwen3.6-27B-GGUF (non-MTP) | 16.8 GB | ✅ but no MTP heads (was the previous default) |
| bartowski/Qwen_Qwen3.6-27B-GGUF | 18.0 GB | ❌ OOMs (keeps embed/output hi-precision) |
| ubergarm/Qwen3.6-27B-GGUF | IQ4_KS 15.8 GB | ❌ no mmproj (text-only) |

To use a different repo/quant, change the `-hf` argument in `llama.container` (keep the
Q4_K_M ≤ ~17 GB and an mmproj in the repo, or add `--no-mmproj` for text-only). The MTP
repo also ships IQ4_XS (15.7 GB), which is small enough to keep the **full 65536** context
with MTP at a slightly lower quant — swap `:Q4_K_M` → `:IQ4_XS` and `-c 49152` → `-c 65536`
if you would rather trade a little quality for context length.

## MTP (speculative decoding)

`--spec-type draft-mtp --spec-draft-n-max 2` enables Multi-Token Prediction: the model's
speculative heads draft up to 2 tokens ahead, the main model verifies them, and only tokens
the main model would have produced anyway are accepted. Output is therefore **identical to
non-MTP** (lossless — bit-for-bit at temperature 0); MTP only changes speed.

Verified on the target (Q4_K_M + MTP, c=49152):

- **~1.85x faster decode:** ~26 tok/s single-stream (vs ~14 non-MTP). Draft acceptance
  0.75–0.97 under load — terminal/code text is highly predictable, so acceptance is high.
- **Multimodal works:** dense 2170×980 screenshots are OCR'd correctly (command lines,
  IPs, error strings, byte counts). Vision decode ~22 tok/s incl. image encode.
- **Single-slot only:** speculation forces `--parallel 1`. MTP is a single-user speedup —
  under concurrent load requests **serialize**, so throughput does not rise and only latency
  grows (a 6-way stress mix held stable but ran one request at a time). If you need many
  simultaneous users, prefer non-MTP with `--parallel 2` (the previous default) instead.
- **Host RAM:** concurrent vision requests decode each ~2.5 MB image to a raw bitmap host
  side; a 6-way vision stress peaked at ~11 GB RSS. Give the VM **≥ 16 GB RAM** (a 8 GB VM
  was OOM-killed by the kernel — a *host* OOM, unrelated to VRAM).

## Config

Flags come from the reference compose (`llama.container` → `Exec=`), with the local
`-m/--mmproj` swapped for `-hf` auto-download and MTP added: `-c 49152` context, `-ngl 99`
(all layers on GPU), `-fa on` (flash attention), `--cache-type-k/v q8_0` (quantized KV
cache), `--jinja --reasoning-format auto`, `--parallel 1` (single slot — required by MTP),
`--spec-type draft-mtp --spec-draft-n-max 2` (MTP speculative decoding), `--metrics`.

- **GPU:** `AddDevice=nvidia.com/gpu=all` (CDI, generated at boot).
- **Networking:** `Network=host`; `--host 0.0.0.0` (IPv4). The host also has IPv6 (SLAAC);
  switch `Exec=` to `--host ::` in `llama.container` if you need to serve IPv6 clients.
- **Model cache:** host `/var/lib/llama/cache` → container `/cache` (`LLAMA_CACHE`).

## Bumping the image

`ghcr.io/ggml-org/llama.cpp:server-cuda` is a rolling tag. bootc re-pulls it into the
bound store on each `bootc upgrade`. Keep the tag in sync between `llama.image` and
`llama.container`.
