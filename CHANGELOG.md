# Changelog

All notable changes to the Aviant Speech Enhancement Server are documented here.

## [0.7.0] - 2026-10-14

Security and maintenance release. **The Docker images now run as a non-root user**, which can break deployments that mount writable volumes. Read the upgrade notes below first.

### Changed
- **Containers run as uid/gid `10001` (user `aviant`) instead of root.** `/app` (binary and weights) stays root-owned and read-only. The server writes only to `/tmp` and to its GPU cache in `/home/aviant/.cache/aviant`. The UID is numeric, so Kubernetes `runAsNonRoot` can verify it
- Image packages are upgraded at build time. The `aviant-wgpu` and `aviant-cuda` images previously shipped the outdated system packages of their NVIDIA base images (openssl, libc, GnuTLS, …), including CVE-2023-4911 and CVE-2026-45447. CUDA libraries stay pinned to 12.6
- Upgraded the compute stack to burn 0.22, cubecl 0.11 and wgpu 30. Enhanced output is bit-identical to 0.6.0 on CPU. On GPU it differs by at most ~0.08 LSB RMS (floating-point summation order), and it is no further from the CPU output than 0.6.0 was
- Building from source requires Rust 1.95 or newer

### Removed
- The Candle backend. It had been disabled and did not compile; `cpu`, `wgpu` and `cuda` are unaffected

### Security
- Dependency updates for advisories in `rustls`, `hyper`, `h2`, `http`, `tar`, `bytes`, `zerocopy`, `rand` and others

### Upgrade notes

1. **Writable mounts.** Any volume the container writes to must be writable by uid `10001`, for example `chown -R 10001:10001 /path/on/host`. Read-only mounts such as the Vulkan ICD mount are unaffected. If a mounted `AVIANT_CACHE_DIR` is not writable, the server still starts, but it puts the GPU cache inside the container instead, so warm starts don't survive a container restart
2. **Pre-warmed images.** Rebuild them from the 0.7.0 base. The GPU cache format changed with the compute-stack upgrade, and the cache now lives in the `aviant` user's home rather than root's, so an image warmed with 0.6.x is no longer warm
3. **Custom `--user`.** Running the image as a different uid (`--user`, Kubernetes `runAsUser`) still works. A uid with no home directory in the image gets its GPU cache in `/tmp`, so set `AVIANT_CACHE_DIR` to a writable, persistent path to keep warm starts

## [0.6.0] - 2026-10-02

Security release.

### Security
- URL mode (`{"url": ...}` on `/v1/enhance` and `/v1/normalize`) only fetches `http`/`https` URLs whose host resolves to public addresses. Loopback, private (RFC 1918), link-local/cloud-metadata and other non-routable addresses are refused with `400`, redirects are not followed, and `HTTP(S)_PROXY` is bypassed for these fetches. To enhance a local file, upload it as multipart instead
- Dependency updates for published security advisories, including `object_store` 0.14 and `reqwest` 0.13

## [0.5.2] - 2026-08-19

### Added
- macOS (Apple Silicon) bundle: a prebuilt, ad-hoc-signed development build. Clear the download flag with `xattr -dr com.apple.quarantine aviant-server` before running it

### Changed
- The GPU kernel cache lives in a fixed per-user directory (`~/.cache/aviant` on Linux, `~/Library/Caches/aviant` on macOS, overridable with `AVIANT_CACHE_DIR`) instead of `./target/autotune` relative to the working directory. Starting from another directory no longer re-pays the full compile, and an unwritable working directory no longer stops the server from starting with a misleading GPU error

### Upgrade notes
- **Pre-warmed images:** the cache moved out of `/app/target/autotune`, so an image warmed by an older version is no longer warm. Re-run `warmup-image.sh` against the new base image once

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
