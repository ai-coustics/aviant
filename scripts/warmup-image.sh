#!/usr/bin/env bash
#
# Build a warmed-up container image by running GPU shader compilation once
# and committing the result. Shaders are specialized per batch size, so
# the warmup must use the same --batch-size as production inference.
#
# Usage:
#   ./scripts/warmup-image.sh [--base IMAGE] [--model MODEL] [--batch-size N] [--tag TAG]
#
# Examples:
#   ./scripts/warmup-image.sh --batch-size 1
#   ./scripts/warmup-image.sh --base ghcr.io/ai-coustics/aviant-wgpu:0.4.4 --model finch --batch-size 2
#   ./scripts/warmup-image.sh --tag my-registry/aviant-warmed:latest --batch-size 1

set -euo pipefail

BASE_IMAGE="ghcr.io/ai-coustics/aviant-wgpu:latest"
MODEL="lark-v2"
BATCH_SIZE="1"
TAG="aviant-wgpu-warmed"
CONTAINER_NAME="aviant-warmup-$$"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)       BASE_IMAGE="$2"; shift 2 ;;
        --model)      MODEL="$2"; shift 2 ;;
        --batch-size) BATCH_SIZE="$2"; shift 2 ;;
        --tag)        TAG="$2"; shift 2 ;;
        *)            echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "=== Warmup Image Builder ==="
echo "Base:       $BASE_IMAGE"
echo "Model:      $MODEL"
echo "Batch size: $BATCH_SIZE"
echo "Tag:        $TAG"
echo ""

# Step 1: Run warmup with GPU access
echo "Step 1: Running warmup (this triggers GPU shader compilation)..."
docker run --gpus all \
    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
    -e __GL_SHADER_DISK_CACHE=1 \
    -e __GL_SHADER_DISK_CACHE_PATH=/cache/nvidia \
    -e __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1 \
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
echo "    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \\"
echo "    $TAG --model $MODEL --batch-size $BATCH_SIZE"
echo ""
echo "  # Compare with cold image:"
echo "  docker run --gpus all -p 8080:8080 \\"
echo "    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \\"
echo "    $BASE_IMAGE --model $MODEL --batch-size $BATCH_SIZE"
