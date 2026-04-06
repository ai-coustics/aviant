# Changelog

All notable changes to the Aviant Speech Enhancement Server are documented here.

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
