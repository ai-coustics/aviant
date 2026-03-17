# Aviant Speech Enhancement Server

Aviant is a self-hosted speech enhancement server by [ai-coustics](https://ai-coustics.com). It takes noisy audio and produces clean, enhanced speech — running entirely on your infrastructure.

## Quick start

**1. Run the server** (requires an NVIDIA GPU):

```bash
docker run --gpus all -p 8080:8080 \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -e SDK_KEY="YOUR-KEY" \
  ghcr.io/ai-coustics/aviant-wgpu:latest --batch-size 1
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

> **Note:** The first request after startup is slow (up to ~80 s on an RTX 3090) due to Vulkan shader optimization. All subsequent requests run at full speed.

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
