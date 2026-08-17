# Aviant Speech Enhancement Server

Aviant is a self-hosted speech enhancement server by [ai-coustics](https://ai-coustics.com). It takes noisy audio and produces clean, enhanced speech — running entirely on your infrastructure.

> **On a Mac, do not use Docker.** No container runtime on macOS can reach the Apple GPU, so the image below resolves to an arm64 CPU build that runs roughly **14x slower** — slower than realtime. See [Running on macOS](#running-on-macos).

## Quick start

**1. Run the server** (requires an NVIDIA GPU):

```bash
docker run --gpus all -p 8080:8080 --restart unless-stopped \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -e SDK_KEY="YOUR-KEY" \
  ghcr.io/ai-coustics/aviant-wgpu:latest --batch-size 1 --model lark-v2
```

`--restart unless-stopped` matters: if the compute device is lost, the server reports `503` and exits so a supervisor can replace it. Without a restart policy it stays down.

**2. Check it's running:**

```bash
curl http://localhost:8080/health
# {"status":"ok", ...}
```

**3. Enhance an audio file:**

```bash
curl -X POST http://localhost:8080/v1/enhance \
  -F audio=@your-audio-file.wav \
  -o enhanced.wav
```

## CUDA backend (no Vulkan required)

For environments without Vulkan drivers (e.g. Azure NC/ND-series VMs), use the CUDA image instead:

```bash
docker run --gpus all -p 8080:8080 \
  -e SDK_KEY="YOUR-KEY" \
  ghcr.io/ai-coustics/aviant-cuda:latest --batch-size 1 --model lark-v2
```

No Vulkan ICD mount needed. Requires NVIDIA driver >= 560.28.

## Host requirements

| | WGPU image (`aviant-wgpu`) | CUDA image (`aviant-cuda`) |
|---|---|---|
| NVIDIA Container Toolkit | required | required |
| Vulkan ICD files | required (mapped via `-v`) | not needed |
| Min NVIDIA driver | any recent | >= 560.28 |
| Platforms | linux/amd64, linux/arm64 (CPU) | linux/amd64 only |

## Performance

`--batch-size` controls how many frames are processed in parallel on the GPU. Each frame corresponds to ~20 s of audio. Processing time scales linearly with batch size.

Model | Frame length | VRAM usage | Time per frame (RTX 3090) |
|---|---|---|---|
Lark v2 | 20s | < 4 GB | ~4.7 s |
Lark v1 | 20s | < 3 GB | ~2.3 s |
Finch v1 | 20s | < 3 GB | ~2.3 s |

> **Note:** The first request after startup is slow (~80 s on an RTX 3090) due to Vulkan shader compilation. Use `--warmup` or build a pre-warmed image to eliminate this. See [Reducing cold start](#reducing-cold-start) below.

## API reference

### `GET /health`

`200` with `"status":"ok"` when the server can serve; `503` with `"status":"unavailable"` and a `reason` when it cannot. Use it as both a liveness and a readiness probe — a `503` means restart, not retry.

```json
{
  "status": "ok",
  "version": "0.5.1",
  "model": "lark-v2",
  "backend": {
    "selected": "wgpu",
    "status": {"cpu": "compiled", "wgpu": "selected", "cuda": "not-compiled"}
  },
  "ffmpeg": {"ffmpeg": true, "ffprobe": true, "loudnorm": true, "deesser": true, "libmp3lame": true},
  "queue": {"depth": 0, "capacity": 16}
}
```

`not-compiled` means this image was built without that backend, which is different from a backend that is present but has no usable device.

### `aviant doctor`

Checks the environment and reports *every* problem in one run, then exits non-zero if the machine could not serve. Run it on a host before deploying, or when opening a support ticket.

```bash
docker run --rm ghcr.io/ai-coustics/aviant-wgpu:latest doctor
docker run --rm ghcr.io/ai-coustics/aviant-wgpu:latest doctor --json
```

It verifies ffmpeg and its required filters, the weight file, the licence key (offline, without printing it), temp-directory writability, the GPU adapters, and that a real tensor operation on the selected device returns the right answer.

### `POST /v1/enhance`

Enhance an audio file synchronously. Returns `audio/wav` (16-bit PCM, 32 kHz mono).

**File upload** (multipart/form-data):

```bash
curl -X POST http://localhost:8080/v1/enhance \
  -H "Authorization: Bearer $SDK_KEY" \
  -F audio=@input.wav \
  -o enhanced.wav
```

**URL mode** (application/json):

```bash
curl -X POST http://localhost:8080/v1/enhance \
  -H "Authorization: Bearer $SDK_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/audio.wav"}' \
  -o enhanced.wav
```

### `POST /v1/normalize`

Normalize an audio file without enhancement. Applies EBU R128 loudness normalization (-17 LUFS) and resamples to 32 kHz mono. Returns `audio/wav`. This is the same preprocessing that runs internally before enhancement, useful when you need the normalized audio separately.

Does not use the GPU or run model inference, so responses are fast (roughly 2-4 seconds per minute of audio).

**File upload** (multipart/form-data):

```bash
curl -X POST http://localhost:8080/v1/normalize \
  -H "Authorization: Bearer $SDK_KEY" \
  -F audio=@input.wav \
  -o normalized.wav
```

**URL mode** (application/json):

```bash
curl -X POST http://localhost:8080/v1/normalize \
  -H "Authorization: Bearer $SDK_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/audio.wav"}' \
  -o normalized.wav
```

### `POST /v1/enhance/async`

Async enhancement via cloud storage. The server downloads from `input_url`, processes the audio, and uploads the result to `output_url`. A preprocessed (normalized, 32 kHz) copy of the input is also uploaded alongside the output as `{input_filename}_preprocessed.wav`.

Supports `s3://` and `az://` (Azure Blob Storage) URLs. Credentials are read from standard environment variables (`AWS_*` for S3, `AZURE_*` for Azure).

```bash
curl -X POST http://localhost:8080/v1/enhance/async \
  -H "Authorization: Bearer $SDK_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "input_url": "s3://my-bucket/input.wav",
    "output_url": "s3://my-bucket/output.wav"
  }'
# Returns 202 Accepted
```

### Error codes

| Status | Meaning | Retry? |
|---|---|---|
| `400` | Bad request — an unsupported upload file extension, or audio that cannot be decoded | No, it will fail identically |
| `401` | Unauthorized — missing, malformed or invalid SDK key | No |
| `500` | Internal server error — processing failed | Maybe |
| `503` | The server cannot serve at all — the compute device was lost, or a required ffmpeg capability is missing | After the restart |

On `503` the process exits so your supervisor restarts it.

## Authentication

Pass your SDK key in one of two ways:

| Method | Usage |
|---|---|
| **Environment variable** | Set `SDK_KEY` when starting the container (applies to all requests) |
| **Bearer token** | Pass `Authorization: Bearer <key>` as a request header |

When both are provided, the header takes precedence. Create SDK keys in the [ai-coustics developer portal](https://developers.ai-coustics.com).

> **`SDK_KEY` serves unauthenticated requests.** With `SDK_KEY` set, a request that carries *no* `Authorization` header is served using it — so anything that can reach the port can spend your licence. For any deployment reachable beyond loopback, set `--allow-env-key false` and have clients send their own header. This default will change in a future major version.

A malformed header (`Basic ...`, a bare token, or `Bearer` with no key) is rejected with `401` rather than falling back to `SDK_KEY`.

## Server options

Run `--help` for the authoritative list.

| Flag | Description | Default |
|---|---|---|
| `--host` | Address to bind | `127.0.0.1` |
| `--port` | Port the server listens on | `8080` |
| `--backend` | Compute backend: `wgpu`, `cuda`, `cpu` | `wgpu` |
| `--model` | Model: `lark-v2`, `lark-v1`, `finch` | `lark-v2` |
| `--batch-size` | Frames processed in parallel on the GPU | unlimited |
| `--weights` | Path to a custom `.aviant` weight file | auto per model setting |
| `--allow-env-key` | Serve requests with no `Authorization` header using the server's own `SDK_KEY` | `true` |
| `--allow-cpu-fallback` | Fall back to the CPU backend if the GPU cannot compute, instead of refusing to start | off |
| `--warmup` | Run a dummy inference at startup to compile GPU shaders before serving | off |
| `--no-warmup` | Disable startup warmup (the default) | — |
| `--warmup-only` | Run warmup then exit. Used for building pre-warmed images | — |

**`--host` defaults to loopback.** A server started by hand serves only the machine it runs on. The published Docker images pass `--host 0.0.0.0` in their entrypoint — a container binding loopback would be unreachable through `-p` — so containers are unaffected.

### Startup checks

The server verifies before it accepts traffic, and refuses to start rather than failing every request later:

- **ffmpeg**: `ffmpeg`, `ffprobe`, `loudnorm`, `deesser` and the `pcm_s16le` encoder must be present. Every missing capability is named at once. `libmp3lame` is optional
- **The compute device**: a real tensor operation must return the right answer on the selected backend. Pass `--allow-cpu-fallback` to fall back to the CPU (roughly 14x slower) instead

## Running on macOS

macOS runs the server **natively**, not in a container. Docker Desktop, Podman, Colima, OrbStack and Apple's `container` tool all run Linux in a VM, and Apple exposes no GPU compute API to VMs — so a container on a Mac cannot reach Metal at any layer, and falls back to a CPU build measured at roughly 14x slower.

> **Development target. Not supported for production deployment.** Apple GPU compute cannot be tested in CI, so we do not promise support for something we cannot verify on every change.

Measured on an M4 Max, lark-v2, `--batch-size 1`, 30.6 s of audio:

| Backend | End-to-end wall | vs realtime |
|---|---|---|
| wgpu (Metal) | **21.2 s** | 0.69x — faster than realtime |
| cpu (NdArray) | 288.8 s | 9.4x — far slower than realtime |

Native macOS packaging (`brew install`) is not released yet. If you need to run Aviant on a Mac today, [get in touch](#support) — do not use the Docker image as a substitute.

### Reaching a native server from your containers

The server binds `127.0.0.1` by default. Docker Desktop and OrbStack both proxy host loopback, so a client container reaches it without widening the bind:

```yaml
services:
  your-client:
    environment:
      # Docker Desktop; use host.orb.internal on OrbStack
      AVIANT_URL: http://host.docker.internal:8080
```

Do **not** pass `--host 0.0.0.0` for this. It is not needed on either runtime, and combined with the default `--allow-env-key` it lets anything on your network spend your licence.

## Reducing cold start

The first inference after startup is slow because GPU kernels are compiled on demand: ~80 s for WGPU/Vulkan on an RTX 3090, 75–120 s for WGPU/Metal on an M4 Max, and longer for CUDA/NVRTC. There are two ways to handle this:

### Option 1: Startup warmup

Add `--warmup` to run a dummy inference during server startup. This compiles all GPU shaders before the server accepts traffic. The container takes longer to start, but user requests are always fast.

```bash
docker run --gpus all -p 8080:8080 \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -e SDK_KEY="YOUR-KEY" \
  ghcr.io/ai-coustics/aviant-wgpu:latest --batch-size 1 --model lark-v2 --warmup
```

### Option 2: Pre-warmed Docker image

Build a new image that bakes in the compiled shader cache. This eliminates the cold start on subsequent container boots, which is useful for scale-to-zero deployments where containers restart frequently.

**Important:** Shaders are specialized per batch size. The warmup must use the same `--batch-size` as production inference.

```bash
# 1. Run warmup on a GPU host (compiles shaders, writes driver caches to disk)
docker run --gpus all \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  --name aviant-warmup \
  ghcr.io/ai-coustics/aviant-wgpu:latest \
  --model lark-v2 --batch-size 1 --warmup-only

# 2. Commit the stopped container as a new image
docker commit aviant-warmup aviant-wgpu-warmed
docker rm aviant-warmup

# 3. Use the warmed image in production
docker run --gpus all -p 8080:8080 \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -e SDK_KEY="YOUR-KEY" \
  aviant-wgpu-warmed --batch-size 1 --model lark-v2
```

Convenience scripts are provided for both backends:

```bash
# WGPU (Vulkan)
./scripts/warmup-image.sh --base ghcr.io/ai-coustics/aviant-wgpu:latest --model lark-v2 --batch-size 1

# CUDA
./scripts/warmup-cuda.sh --base ghcr.io/ai-coustics/aviant-cuda:latest --model lark-v2 --batch-size 1
```

## Input and output

- **Input**: most audio formats and sample rates (ffmpeg-based decoding)
- **Output**: mono WAV, 16-bit PCM, 32 kHz
- **Concurrency**: the server accepts concurrent requests and queues them in front of the inference engine

## Azure deployment

Azure NC/ND-series VMs have NVIDIA GPUs with CUDA but typically no Vulkan drivers. Use the CUDA image:

1. Create an NC-series VM (e.g. NC4as_T4_v3) or AKS GPU node pool
2. Install [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
3. Verify GPU access: `nvidia-smi` should show driver >= 560.28
4. Run the CUDA image:

```bash
docker run --gpus all -p 8080:8080 \
  -e SDK_KEY="YOUR-KEY" \
  ghcr.io/ai-coustics/aviant-cuda:latest --warmup --batch-size 1 --model lark-v2
```

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `CUDA driver initialization failed` | Driver too old or missing | Update to NVIDIA driver >= 560.28 |
| `No CUDA devices found` | Container can't see GPU | Add `--gpus all` to `docker run` |
| `NVRTC compilation error` | Missing CUDA headers | Use the official `aviant-cuda` image (headers are baked in) |
| Slow first request | Kernel compilation (expected) | Use `--warmup` flag or pre-warm with `warmup-cuda.sh` |

## Limitations

- Processing very long files (1 h @ 32 kHz mono, ~230 MB) may exhaust host memory. `--batch-size` does not control this: the pipeline computes the STFT for every frame before batching begins, so host memory scales with the *length of the input*. Split inputs longer than ~10 minutes
- Processing many small files concurrently may exhaust disk I/O (file-based pipeline)
- The inference queue holds 16 requests; beyond that, requests wait. Watch `queue.depth` in `/health`
- The server authenticates and sends usage telemetry to the ai-coustics backend. Contact us to discuss air-gapped deployments

## Support

- [Developer portal](https://developers.ai-coustics.com)
- [Discord](https://discord.gg/wrSthtNqQ4)
