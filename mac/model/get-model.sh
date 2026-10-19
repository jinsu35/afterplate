#!/bin/bash
# Optional: the on-device model that tells a meal photo from food merely being
# in the frame. Without it the app sorts photos with Apple Vision alone and
# misses some meals (a laid table outdoors, a bowl of 빙수).
#
# Downloads google/siglip-base-patch16-224 (Apache 2.0, about 800MB) from
# Hugging Face and converts its image tower to Core ML on this Mac, at
# mac/Afterplate/SigLIPImage.mlpackage. Needs uv (brew install uv).
set -euo pipefail
cd "$(dirname "$0")"
ENV="${AFTERPLATE_MODEL_ENV:-$HOME/Library/Caches/afterplate-model-env}"
[[ -d "$ENV" ]] || uv venv -q --python 3.12 "$ENV"
# The versions this conversion was tested with: coremltools is tested against
# torch 2.7, and the transformers that supports SigLIP on it.
VIRTUAL_ENV="$ENV" uv pip install -q "torch==2.7.0" "torchvision==0.22.0" "transformers==4.51.3" \
  "coremltools==9.0" sentencepiece protobuf numpy
"$ENV/bin/python" convert-siglip.py
