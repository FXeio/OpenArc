# ============================================================================
# OpenARC - Ubuntu 24.04 + Legacy Intel OpenCL runtime for Gemini Lake
# ============================================================================

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================================
# System dependencies
# ============================================================================

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gpg \
    gpg-agent \
    wget \
    python3 \
    python3-venv \
    python3-dev \
    python3-pip \
    build-essential \
    cmake \
    libudev-dev \
    clinfo \
    ocl-icd-libopencl1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3 1 \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# Intel legacy OpenCL / Level Zero runtime for pre-Gen12 iGPU
# Gemini Lake / UHD 600 needs the legacy 24.35 line, not current noble packages
# ============================================================================

RUN mkdir -p /tmp/neo && cd /tmp/neo && \
    wget https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.20/intel-igc-core_1.0.17537.20_amd64.deb && \
    wget https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.20/intel-igc-opencl_1.0.17537.20_amd64.deb && \
    wget https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/libigdgmm12_22.5.0_amd64.deb && \
    wget https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/intel-opencl-icd-legacy1_24.35.30872.22_amd64.deb && \
    wget https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/intel-level-zero-gpu-legacy1_1.3.30872.22_amd64.deb && \
    dpkg -i ./*.deb || apt-get -f install -y && \
    ldconfig && \
    rm -rf /tmp/neo

# ============================================================================
# Intel NPU driver (leave as-is from your fork)
# ============================================================================

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    build-essential \
    libudev-dev && \
    git clone https://github.com/intel/linux-npu-driver.git /tmp/npu-driver && \
    cd /tmp/npu-driver && \
    git submodule update --init --recursive && \
    mkdir build && cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local .. && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    cd / && rm -rf /tmp/npu-driver /var/lib/apt/lists/*

# ============================================================================
# Install uv
# ============================================================================

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# ============================================================================
# App code
# ============================================================================

WORKDIR /app
COPY . /app
RUN echo "OpenARC fork build"

# ============================================================================
# Python deps
# Assumes pyproject.toml is already pinned to:
#   openvino==2025.4
#   openvino-genai==2025.4
#   openvino-tokenizers==2025.4
#   optimum==1.27.0
#   optimum-intel[openvino]==1.25.2
#   transformers==4.51.3
#   torch==2.8.0
#   torchvision==0.23.0
# ============================================================================

RUN rm -f uv.lock && \
    uv sync --refresh --reinstall

ENV PATH="/app/.venv/bin:$PATH"

# ============================================================================
# Runtime configuration
# ============================================================================

ENV NEOReadDebugKeys=1 \
    OverrideGpuAddressSpace=48 \
    EnableImplicitScaling=1 \
    OPENARC_API_KEY=key \
    OPENARC_AUTOLOAD_MODEL=""

# Persistent config
RUN mkdir -p /persist && \
    ln -sf /persist/openarc_config.json /app/openarc_config.json

# ============================================================================
# Build info
# ============================================================================

RUN echo "=== Build Information ===" > /app/BUILD_INFO.txt && \
    echo "Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> /app/BUILD_INFO.txt && \
    echo "OpenARC Version: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >> /app/BUILD_INFO.txt && \
    echo "" >> /app/BUILD_INFO.txt && \
    echo "=== Intel Package Versions ===" >> /app/BUILD_INFO.txt && \
    uv pip list | grep -E "(openvino|optimum|torch)" >> /app/BUILD_INFO.txt || true && \
    echo "" >> /app/BUILD_INFO.txt && \
    echo "=== System Package Versions ===" >> /app/BUILD_INFO.txt && \
    dpkg -l | grep -E "intel-opencl|level-zero|igdgmm|igc" | awk '{print $2 " " $3}' >> /app/BUILD_INFO.txt || true

# ============================================================================
# Startup script
# ============================================================================

RUN cat > /usr/local/bin/start-openarc.sh <<'SCRIPT'
#!/bin/bash
set -e

echo "================================================"
echo "=== Starting OpenArc Server ==="
echo "================================================"

if [ -f /app/BUILD_INFO.txt ]; then
  cat /app/BUILD_INFO.txt
  echo ""
fi

echo "=== OpenCL sanity ==="
ls -l /etc/OpenCL/vendors || true
cat /etc/OpenCL/vendors/*.icd 2>/dev/null || true
clinfo | head -40 || true
python - <<'PY' || true
import openvino as ov
print("OpenVINO devices:", ov.Core().available_devices)
PY
echo ""

echo "=== Runtime Configuration ==="
echo "Port: 8000"
echo "API Key: ${OPENARC_API_KEY:0:10}..."
echo "Auto-load Model: ${OPENARC_AUTOLOAD_MODEL:-none}"
echo ""
echo "================================================"

openarc serve start --host 0.0.0.0 --port 8000 &
SERVER_PID=$!

if [ -n "$OPENARC_AUTOLOAD_MODEL" ]; then
  echo "Waiting for server to start..."
  for i in {1..30}; do
    if curl -s -f -H "Authorization: Bearer ${OPENARC_API_KEY}" http://localhost:8000/v1/models >/dev/null 2>&1; then
      echo "Server ready after $i seconds"
      echo "Auto-loading model: $OPENARC_AUTOLOAD_MODEL"
      openarc load "$OPENARC_AUTOLOAD_MODEL" || echo "Failed to auto-load model"
      break
    fi
    sleep 1
  done
fi

wait $SERVER_PID
SCRIPT

RUN chmod +x /usr/local/bin/start-openarc.sh

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD curl -f -H "Authorization: Bearer ${OPENARC_API_KEY}" http://localhost:8000/v1/models || exit 1

CMD ["/usr/local/bin/start-openarc.sh"]
