# Aviant Speech Enhancement Server

Aviant is a self-hosted speech enhancement server by [ai-coustics](https://ai-coustics.com). It takes noisy audio and produces clean, enhanced speech — running entirely on your infrastructure.

## Quick start

**1. Run the server** (requires an NVIDIA GPU):

```bash
docker run --gpus all -p 8080:8080 \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -e SDK_KEY="YOUR-KEY" \
  ghcr.io/ai-coustics/aviant-wgpu:latest --batch-size 1 --model lark-v2
```

**2. Check it's running:**

```bash
curl http://localhost:8080/health
# {"status":"ok"}
```

**3. Enhance an audio file:**

```bash
curl -X POST http://localhost:8080/v1/enhance \
  -F audio=@your-audio-file.wav \
  -o enhanced.wav
```

## Host requirements

- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) installed
- Vulkan ICD files available on the host (comes with NVIDIA drivers) — mapped into the container via `-v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro`

## Performance

`--batch-size` controls how many frames are processed in parallel on the GPU. Each frame corresponds to ~20 s of audio. Processing time scales linearly with batch size.

Model | Frame length | VRAM usage | Time per frame (RTX 3090) |
|---|---|---|---|
Lark v2 | 20s | < 4 GB | ~4.7 s |
Lark v1 | 20s | < 3 GB | ~2.3 s |
Finch v1 | 20s | < 3 GB | ~2.3 s |

> **Note:** The first request after startup is slow (up to ~80 s on an RTX 3090) due to Vulkan shader compilation. Use `--warmup` or build a pre-warmed image to eliminate this. See [Reducing cold start](#reducing-cold-start) below.

## API reference

### `GET /health`

Returns `{"status":"ok"}` when the server is ready.

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

| Status | Meaning |
|---|---|
| `400` | Bad request — invalid audio format or missing parameters |
| `401` | Unauthorized — missing or invalid SDK key |
| `500` | Internal server error — processing failed |

## Authentication

Pass your SDK key in one of two ways:

| Method | Usage |
|---|---|
| **Environment variable** | Set `SDK_KEY` when starting the container (applies to all requests) |
| **Bearer token** | Pass `Authorization: Bearer <key>` as a request header |

When both are provided, the header takes precedence. Create SDK keys in the [ai-coustics developer portal](https://developers.ai-coustics.com).

## Server options

| Flag | Description | Default |
|---|---|---|
| `--port` | Port the server listens on | `8080` |
| `--model` | Model: `lark-v2`, `lark-v1`, `finch` | `lark-v2` |
| `--batch-size` | Frames processed in parallel on the GPU | unlimited |
| `--weights` | Path to a custom `.aviant` weight file | auto per model setting |
| `--warmup` | Run a dummy inference at startup to compile GPU shaders before serving | off |
| `--no-warmup` | Disable startup warmup (the default) | — |
| `--warmup-only` | Run warmup then exit. Used for building pre-warmed images | — |

## Reducing cold start

The first inference after startup takes 45-80 s because the GPU shaders are compiled on demand. There are two ways to handle this:

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

A convenience script is available in the [SDK repository](https://github.com/ai-coustics/aviant-sdk/blob/main/scripts/warmup-image.sh):

```bash
./scripts/warmup-image.sh --base ghcr.io/ai-coustics/aviant-wgpu:latest --model lark-v2 --batch-size 1
```

## Input and output

- **Input**: most audio formats and sample rates (ffmpeg-based decoding)
- **Output**: mono WAV, 16-bit PCM, 32 kHz
- **Concurrency**: the server accepts concurrent requests and queues them in front of the inference engine

## Limitations

- Processing very long files (1 h @ 32 kHz mono, ~230 MB) may exhaust memory
- Processing many small files concurrently may exhaust disk I/O (file-based pipeline)
- The server authenticates and sends usage telemetry to the ai-coustics backend. Contact us to discuss air-gapped deployments

## Support

- [Developer portal](https://developers.ai-coustics.com)
- [Discord](https://discord.gg/wrSthtNqQ4)
