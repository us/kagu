#!/bin/sh
# Builds a standalone whisper-cli (static, Metal embedded) and copies it with the VAD model into vendor/.
set -eu
cd "$(dirname "$0")/.."
TAG=v1.9.5
SRC=work/whisper.cpp
VAD_URL=https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
VAD_SHA256=29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf

[ -d "$SRC" ] || git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
cmake --build "$SRC/build" --config Release -j 8 --target whisper-cli

mkdir -p vendor
cp "$SRC/build/bin/whisper-cli" vendor/whisper-cli
cp "$SRC/LICENSE" vendor/LICENSE-whisper.cpp
[ -f vendor/ggml-silero-v5.1.2.bin ] || curl -L --fail -o vendor/ggml-silero-v5.1.2.bin "$VAD_URL"
echo "$VAD_SHA256  vendor/ggml-silero-v5.1.2.bin" | shasum -a 256 -c -
echo "built $(pwd)/vendor/whisper-cli"
