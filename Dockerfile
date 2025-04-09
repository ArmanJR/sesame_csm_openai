# Multi-stage build for authenticated model downloads
FROM python:3.10-slim AS model-downloader
# Install huggingface-cli
RUN pip install huggingface_hub
# Set working directory
WORKDIR /model-downloader
# Create directory for downloaded models
RUN mkdir -p /model-downloader/models
# This will run when building the image
# You'll need to pass your Hugging Face token at build time
ARG HF_TOKEN
ENV HF_TOKEN=${HF_TOKEN}
# Login and download model
RUN if [ -n "$HF_TOKEN" ]; then \
    huggingface-cli login --token ${HF_TOKEN}; \
    huggingface-cli download sesame/csm-1b ckpt.pt --local-dir /model-downloader/models; \
    else echo "No HF_TOKEN provided, model download will be skipped"; fi

# Now for the main application stage
FROM nvidia/cuda:12.4.0-base-ubuntu22.04

ENV PYTHONFAULTHANDLER=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=random \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_DEFAULT_TIMEOUT=100 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    TORCH_CUDA_ARCH_LIST="7.0;7.5;8.0;8.6" \
    TORCH_NVCC_FLAGS="-Xfatbin -compress-all"

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-dev \
    ffmpeg \
    git \
    build-essential \
    curl \
    cmake \
    libopus-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Rust (needed by sphn)
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y && \
    . "$HOME/.cargo/env" && \
    rustc --version && cargo --version

# Set CMake flag for compatibility workaround
ENV CMAKE_ARGS="-DCMAKE_POLICY_VERSION_MINIMUM=3.5"

WORKDIR /app

# Copy requirements file
COPY requirements.txt .

# Upgrade pip and install Python dependencies; the CMAKE_ARGS will be applied to native builds
RUN . "$HOME/.cargo/env" && pip3 install --upgrade pip && \
    pip3 install -r requirements.txt

# Copy requirements first for better caching
COPY requirements.txt .

# Create and set up persistent directories with proper permissions
RUN mkdir -p /app/static /app/models /app/voice_memories /app/voice_references \
    /app/voice_profiles /app/cloned_voices /app/audio_cache /app/tokenizers /app/logs && \
    chmod -R 777 /app/voice_references /app/voice_profiles /app/voice_memories \
    /app/cloned_voices /app/audio_cache /app/static /app/logs /app/tokenizers /app/models

# Copy static files
COPY ./static /app/static

# Install Python dependencies
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install torch torchaudio numpy

# Install torchao from source
RUN pip3 install torchao --extra-index-url https://download.pytorch.org/whl/cu126

# Install torchtune from source with specific branch for latest features
RUN git clone https://github.com/pytorch/torchtune.git /tmp/torchtune && \
    cd /tmp/torchtune && \
    # Try to use the main branch, which should have llama3_2
    git checkout main && \
    pip install -e .

# Install remaining dependencies
RUN pip3 install -r requirements.txt

# Install additional dependencies for streaming and voice cloning
RUN pip3 install yt-dlp openai-whisper

# Copy application code
COPY ./app /app/app

# Copy downloaded model from the model-downloader stage
COPY --from=model-downloader /model-downloader/models /app/models

# Show available models in torchtune
RUN python3 -c "import torchtune.models; print('Available models in torchtune:', dir(torchtune.models))"

# Expose port
EXPOSE 8000

# Command to run the application
CMD ["python3", "-m", "app.main"]
