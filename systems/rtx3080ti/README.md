# RTX 3080 Ti system image — vLLM serving notes

Serves **Qwen3.5-9B (cyankiwi AWQ 4-bit)** as `qwen3.5-9b` via the `vllm.container`
Quadlet, image `vllm/vllm-openai:v0.25.1`, on the RTX 3080 Ti (12 GB).

## Why `max-model-len` is 43000 and not 80000

The upstream (docker-compose) reference config ran this same model on the same card at
**80000** context. On this image it does **not** fit at 80000 with CUDA graphs — the
cause is a **known, open vLLM bug**, not our configuration:

**[vLLM #36973](https://github.com/vllm-project/vllm/issues/36973)** — `_warmup_prefill_kernels`
in `qwen3_next.py` leaks GPU memory: it autotunes the `chunk_gated_delta_rule` Triton
kernels (the GDN / linear-attention path that Qwen3.5 uses) and the compiled `.cubin`
binaries stay resident in the CUDA context despite `empty_cache()`. Introduced by PR
**#36599**. It reserves ~1.6 GiB on this 12 GB card (≈3.4 GiB on larger reports), which
drops the KV cache below what 80000 needs. Related: [#26300](https://github.com/vllm-project/vllm/issues/26300)
(stale tracking issue), [#45178](https://github.com/vllm-project/vllm/issues/45178) (a
*different*, smaller profiler-estimate effect — not the cause here).

Consequences (all measured on VM 110, RTX 3080 Ti, driver 580, single-stream = 512
output tokens, `ignore_eos`):

| Config | Context | Single-stream | Note |
|---|---|---|---|
| **v0.25.1, CUDA graphs, `max-model-len 43000`** (current) | 43000 | **~110 tok/s** | graph-accelerated ceiling ≈ 43800 |
| v0.25.1, graphs, `--kv-cache-dtype fp8` | ~60000 | ~107 tok/s | fp8 halves KV/token; slight KV-quality cost |
| v0.25.1, graphs, 80000 | — | — | does NOT serve (KV 1.4 < 2.5 GiB needed) |
| v0.25.1, `--enforce-eager`, 80000 | 80000 | ~27 tok/s | eager skips the leaky warmup but kills graph speed (~4×) |
| v0.25.1, graphs, 80000, `--cpu-offload-gb 2` | 80000 | ~11 tok/s | fits but streams weights over PCIe — not worth it |
| old nightly `0.23.1rc1.dev748` (pre-#36599), graphs | 80000 | ~108 tok/s | the reference setup; digest `sha256:62430cdbb1ccd8963ca213335610d0a9d7bfbc07c2023af55f4d2cdc332e2496` |

We picked **graphs + 43000** to keep the ~110 tok/s decode speed on a stable release,
accepting the reduced context, rather than pin a frozen nightly.

## When revisiting this

- **Check if [#36973](https://github.com/vllm-project/vllm/issues/36973) is fixed.** Once
  the warmup `.cubin` leak is released in a stable vLLM, bump the image tag in
  `files/usr/share/containers/systemd/vllm.image` + `vllm.container` and restore
  `--max-model-len 80000`; the full 80k + graph speed should return with no other change.
- **Want more context now?** Add `--kv-cache-dtype fp8` and raise `--max-model-len` to
  ~60000 (measured: serves, ~107 tok/s). Only tradeoff is fp8-quantized KV cache.
- **Need the exact old behaviour (80k + speed)?** Pin the pre-#36599 nightly by digest
  (see table). Reproducible but frozen — misses later vLLM fixes/features.
- Do **not** reach for `--enforce-eager` (4× slower) or `--cpu-offload-gb` (PCIe-bound)
  to fit 80k — both were measured and rejected.

## How to re-measure

On a host with the GPU (e.g. VM 110), stop the service, run the image with `podman run`
+ `--device nvidia.com/gpu=all`, wait for `/health`, then POST to
`/v1/chat/completions` with `ignore_eos` + fixed `max_tokens` and divide tokens by
latency. The `Available KV cache memory: … GiB` line in the vLLM startup log tells you
whether a given `max-model-len` fits.
