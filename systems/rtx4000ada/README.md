# RTX 4000 Ada system image — llama.cpp serving notes

Serves **Qwen3.6-27B (Q4_K_M GGUF, multimodal)** as `qwen3.6-27b` via the `llama.container`
Quadlet, image `ghcr.io/ggml-org/llama.cpp:server-cuda`, on the RTX 4000 Ada (20 GB).
Ported from a reference docker-compose into the bootc Quadlet path (no compose), mirroring
the rtx3080ti system's approach.

## Model download (automatic — no manual step)

The weights are **not** baked into the image and you do **not** download them by hand.
`llama.container` uses llama.cpp's `-hf unsloth/Qwen3.6-27B-GGUF:Q4_K_M`, which on first
start downloads the Q4_K_M GGUF **and** the matching mmproj (vision projector)
automatically from Hugging Face (~18 GB total). The download is cached under
`LLAMA_CACHE=/cache` → host `/var/lib/llama/cache`, so it happens once and survives
reboots/upgrades. The service is enabled by default; on first boot it fetches the model,
then serves the OpenAI-compatible API + `/metrics` on port 8000 (first start takes a
while — see `TimeoutStartSec`).

### Why this specific repo (20 GB VRAM budget)

On the 20 GB RTX 4000 (SFF) Ada, the model + mmproj (~0.9 GB) + 65536-token q8_0 KV cache
(~2.9 GB) + compute must fit in 20 GB, so the Q4_K_M file must be **≤ ~17 GB**:

| Repo | Q4_K_M | Fits 65k on 20 GB? |
|---|---:|---|
| **unsloth/Qwen3.6-27B-GGUF** (current) | 16.8 GB | ✅ verified (19.5/20.5 GiB used) |
| bartowski/Qwen_Qwen3.6-27B-GGUF | 18.0 GB | ❌ OOMs (keeps embed/output hi-precision) |
| ggml-org/Qwen3.6-27B-GGUF | 19.1 GB | ❌ too big |
| ubergarm/Qwen3.6-27B-GGUF | IQ4_KS 15.8 GB | ❌ no mmproj (text-only) |

To use a different repo/quant, change the `-hf` argument in `llama.container` (keep the
Q4_K_M ≤ ~17 GB and an mmproj in the repo, or add `--no-mmproj` for text-only).

## Config

Flags come from the reference compose (`llama.container` → `Exec=`), with the local
`-m/--mmproj` swapped for `-hf` auto-download: `-c 65536` context, `-ngl 99` (all layers
on GPU), `-fa on` (flash attention), `--cache-type-k/v q8_0` (quantized KV cache),
`--jinja --reasoning-format auto`, `--parallel 2` (2 server slots), `--metrics`.

- **GPU:** `AddDevice=nvidia.com/gpu=all` (CDI, generated at boot).
- **Networking:** `Network=host`; `--host 0.0.0.0` (IPv4). The host also has IPv6 (SLAAC);
  switch `Exec=` to `--host ::` in `llama.container` if you need to serve IPv6 clients.
- **Model cache:** host `/var/lib/llama/cache` → container `/cache` (`LLAMA_CACHE`).

## Bumping the image

`ghcr.io/ggml-org/llama.cpp:server-cuda` is a rolling tag. bootc re-pulls it into the
bound store on each `bootc upgrade`. Keep the tag in sync between `llama.image` and
`llama.container`.
