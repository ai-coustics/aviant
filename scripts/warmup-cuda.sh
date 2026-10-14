#!/usr/bin/env bash
#
# Build a warmed-up CUDA container image by running NVRTC kernel compilation
# once and committing the result. Kernels are specialized per batch size, so
# the warmup must use the same --batch-size as production inference.
#
# Usage:
#   ./scripts/warmup-cuda.sh [--base IMAGE] [--model MODEL] [--batch-size N] [--tag TAG]
#
# Examples:
#   ./scripts/warmup-cuda.sh --batch-size 1
#   ./scripts/warmup-cuda.sh --base ghcr.io/ai-coustics/aviant-cuda:0.4.4 --model finch --batch-size 2
#   ./scripts/warmup-cuda.sh --tag my-registry/aviant-cuda-warmed:latest --batch-size 1

set -euo pipefail

BASE_IMAGE="ghcr.io/ai-coustics/aviant-cuda:latest"
MODEL="lark-v2"
BATCH_SIZE="1"
TAG="aviant-cuda-warmed"
CONTAINER_NAME="aviant-cuda-warmup-$$"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)       BASE_IMAGE="$2"; shift 2 ;;
        --model)      MODEL="$2"; shift 2 ;;
        --batch-size) BATCH_SIZE="$2"; shift 2 ;;
        --tag)        TAG="$2"; shift 2 ;;
        *)            echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "=== CUDA Warmup Image Builder ==="
echo "Base:       $BASE_IMAGE"
echo "Model:      $MODEL"
echo "Batch size: $BATCH_SIZE"
echo "Tag:        $TAG"
echo ""

# Step 1: Run warmup with GPU access
# CUDA JIT caching: NVRTC compiles kernels to PTX at first run.
# Setting CUDA_CACHE_DISABLE=0 enables the persistent compute cache.
echo "Step 1: Running warmup (this triggers NVRTC kernel compilation)..."
docker run --gpus all \
    -e CUDA_CACHE_DISABLE=0 \
    -e CUDA_CACHE_PATH=/cache/cuda \
    -e CUDA_CACHE_MAXSIZE=4294967296 \
    --name "$CONTAINER_NAME" \
    "$BASE_IMAGE" \
    --model "$MODEL" --batch-size "$BATCH_SIZE" --warmup-only

echo ""

# Step 2: Inspect what files were written during warmup
echo "Step 2: Inspecting cached files..."
docker diff "$CONTAINER_NAME" | head -50 || true
echo ""

# Step 3: Commit as new image
echo "Step 3: Committing warmed container as $TAG..."
docker commit "$CONTAINER_NAME" "$TAG"
docker rm "$CONTAINER_NAME"

echo ""
echo "Done! Test the warmed image (use the same --batch-size for inference):"
echo ""
echo "  # Warmed image:"
echo "  docker run --gpus all -p 8080:8080 \\"
echo "    $TAG --model $MODEL --batch-size $BATCH_SIZE"
echo ""
echo "  # Compare with cold image:"
echo "  docker run --gpus all -p 8080:8080 \\"
echo "    $BASE_IMAGE --model $MODEL --batch-size $BATCH_SIZE"
