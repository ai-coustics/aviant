# Changelog

All notable changes to the Aviant Speech Enhancement Server are documented here.

## [0.6.0] - 2026-10-02

Security release. URL mode now refuses addresses that are not public — read the upgrade notes if you fetch audio from an internal host.

### Changed
- **URL mode only fetches from public addresses.** `/v1/enhance` and `/v1/normalize` with a JSON `{"url": ...}` body accept `http` and `https` only. The request is refused with `400` if the host resolves to any loopback, private (RFC 1918), link-local or cloud-metadata (`169.254.169.254`), shared (CGNAT), unique-local IPv6 or other non-routable address, including IPv4-mapped and NAT64 forms of those
- URL mode does not follow redirects. A URL that answers with a `3xx` gets `400`
- URL mode ignores `HTTP_PROXY` and `HTTPS_PROXY` and connects directly to the address it checked
- URL downloads time out after 120 s
- GPU runtime upgraded (burn 0.21, wgpu 29)

### Security
- Fixed server-side request forgery (SSRF) in URL mode. Before this release, a caller with a valid key could make the server fetch internal services or cloud instance metadata. DNS rebinding is also blocked: the download is pinned to the addresses that passed the check
- Updated dependencies with published advisories (`quinn-proto`, `rustls-webpki`, `zerovec`, `quick-xml`, `gix-validate`)

### Upgrade notes

1. **URL mode and internal hosts.** If you pass URLs that point at `localhost`, a private network or a redirecting link, upload the file as `multipart/form-data` instead, or use `/v1/enhance/async` with `s3://` / `az://`, which is unaffected
2. **Pre-warmed images.** A warmed image keeps the version it was built from. Re-run `warmup-image.sh` or `warmup-cuda.sh` against the 0.6.0 base image

## [0.5.2] - 2026-08-18

### Fixed
- The GPU shader cache no longer depends on the working directory. Starting from a different directory re-paid the full compile (~105 s instead of ~10 s), and starting from a directory the server could not write to made it refuse to start with a misleading "failed its smoke test" GPU error

### Changed
- The cache now lives in a fixed per-user directory: `~/Library/Caches/aviant` on macOS, `$XDG_CACHE_HOME/aviant` or `~/.cache/aviant` on Linux, `$TMPDIR/aviant-cache` when there is no `HOME`. In the Docker images it moved from `/app/target/autotune` to `/root/.cache/aviant`

### Added
- `AVIANT_CACHE_DIR` to override the cache location
- `aviant doctor` reports the cache path and whether it is warm. The server prints the path at startup

### Upgrade notes

1. **Pre-warmed images.** An image warmed by 0.5.1 or earlier has its cache in the old location and is no longer warm. Re-run `warmup-image.sh` against the new base image once

## [0.5.1] - 2026-08-17

### Added
- macOS (Apple Silicon) guidance: run the server natively, not in a container. No container runtime on macOS can reach the Apple GPU, so the Docker image resolves to an arm64 CPU build that runs roughly 14x slower — slower than realtime
- Documented how a client container reaches a natively-run server on the same Mac (`host.docker.internal` on Docker Desktop, `host.orb.internal` on OrbStack), verified end-to-end

### Changed
- Corrected the cold-start figures. Shader compilation measures 75–120 s on Apple Silicon (Metal) and ~80 s on an RTX 3090 (Vulkan); the previous "45–80 s" understated it. Warmup results are cached on disk relative to the process's working directory, which is why a pre-warmed image removes the cost on later container boots

## [0.5.0] - 2026-08-17

Reliability and security release. Several changes can stop a **running deployment from restarting** — read the upgrade notes below first.

### Added
- `aviant doctor` subcommand: checks ffmpeg and its filters, the weight file, the licence key (offline), temp-directory writability, GPU adapters, and whether a real tensor operation on the selected device returns the right answer. Reports every problem in one pass and exits non-zero if the machine cannot serve. `--json` for scripts and support tickets
- `GET /health` reports real readiness instead of a constant: `200` while the server can serve, `503` with a `reason` once it cannot. The payload adds the selected backend, which backends the image was built with, ffmpeg capabilities and inference queue depth
- `--host` to control the bind address
- `--allow-env-key BOOL` to control whether requests with no `Authorization` header are served using the server's own `SDK_KEY`
- `--allow-cpu-fallback` to start on the CPU backend when the GPU cannot compute, instead of refusing to start
- `--help` and `--version`
- Startup warning when the CPU backend runs on aarch64 in a container, naming the native path as the fix

### Changed
- **`--host` now defaults to `127.0.0.1`** instead of `0.0.0.0`. The published Docker images pass `--host 0.0.0.0` in their entrypoint and are unaffected
- Startup fails if ffmpeg is incomplete. `ffmpeg`, `ffprobe`, `loudnorm`, `deesser` and the `pcm_s16le` encoder are verified before serving, and every missing capability is named at once. `libmp3lame` remains optional
- Startup fails if the GPU cannot compute, verified with a real tensor operation rather than adapter enumeration
- On device loss the server answers the in-flight request, flips `/health` to `503`, and exits `70` so a supervisor restarts it. **Run with a restart policy** (`--restart unless-stopped`, or a Kubernetes liveness probe)
- Upload file extensions are checked against an allowlist; an unrecognised extension gets `400` with the allowed list. Common audio and video containers are accepted in any case
- Invalid command-line arguments exit `2`, and an unknown `--backend` value is rejected at parse time
- A busy port, a privileged port or a bad `--host` produce a clear message naming the cause and the fix, instead of a panic

### Fixed
- `/health` no longer reports `ok` after the model thread has died — the case where an orchestrator kept a container in service while every request failed
- Audio that cannot be decoded returns `400` instead of `500`, so an orchestrator does not retry a request that can never succeed. `/v1/enhance` and `/v1/normalize` classify it the same way
- A malformed `Authorization` header (`Basic ...`, a bare token, or `Bearer` with no key) is rejected with `401` instead of silently falling back to the server's own `SDK_KEY`
- An invalid `input_url` extension on `/v1/enhance/async` is rejected with `400` before the `202`, rather than failing invisibly in the background. Extensionless object keys are accepted

### Upgrade notes

1. **Binding.** A native install that relied on remote access is loopback-only until it passes `--host 0.0.0.0`. The shipped images already do
2. **ffmpeg.** A deployment limping along with a partial ffmpeg will refuse to start and name what is missing
3. **GPU.** A host whose GPU cannot compute will refuse to start. Pass `--allow-cpu-fallback` (roughly 14x slower) or `--backend cpu` to choose it deliberately
4. **Restart policy.** `503` now means the process is exiting to be restarted. Without a restart policy it stays down

Run `aviant doctor` on the target host before upgrading.

## [0.4.5] - 2026-04-11

### Added
- CUDA backend support (`--backend cuda`) for environments without Vulkan (e.g. Azure NC/ND-series VMs)
- CUDA Docker image (`ghcr.io/ai-coustics/aviant-cuda`) with automatic driver validation and GPU diagnostics
- CUDA warmup script (`scripts/warmup-cuda.sh`) for pre-warming CUDA Docker images
- Azure deployment documentation with troubleshooting guide

## [0.4.4] - 2026-04-06

### Added
- GPU shader warmup (`--warmup`, `--warmup-only`) to eliminate cold start latency on first request
- Pre-warmed Docker image workflow for scale-to-zero deployments
- `scripts/warmup-image.sh` convenience script for building warmed images

## [0.4.3] - 2026-04-05

### Added
- `/v1/normalize` endpoint for standalone loudness normalization and resampling (no GPU required)
- Vulkan adapter logging at startup for GPU diagnostics

## [0.4.2] - 2026-03-20

### Added
- ARM64 container image support

## [0.4.1] - 2026-03-19

### Added
- Lark v1 model support (`--model lark-v1`)
- S3 and Azure Blob Storage support for async enhancement (`s3://`, `az://` URLs)
- Docker image version tagging

### Fixed
- CPU backend (NdArray) now works correctly

## [0.3.0] - 2026-03-12

### Added
- Initial release with Lark v2 and Finch v2 models
- WGPU (Vulkan) GPU backend
- `/v1/enhance` and `/v1/enhance/async` endpoints
- SDK key authentication and usage telemetry
- Float16 weights and inference
