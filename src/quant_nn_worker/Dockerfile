FROM python:3.11-slim
WORKDIR /worker

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH="/worker:/worker/quant_nn_engine"

# Install worker & engine dependencies (CPU-only PyTorch on x86_64 avoids ~4GB CUDA bloat)
COPY src/quant_nn_worker/requirements.txt ./
RUN set -eux; \
    tr -d '\r' < requirements.txt > /tmp/req-clean.txt; \
    if [ "$(uname -m)" = "x86_64" ] && grep -qiE '^torch([=<>!~[:space:]]|$)' /tmp/req-clean.txt; then \
        grep -iE '^torch([=<>!~[:space:]]|$)' /tmp/req-clean.txt > /tmp/req-torch.txt; \
        grep -viE '^torch([=<>!~[:space:]]|$)' /tmp/req-clean.txt > /tmp/req-rest.txt || true; \
        pip install --index-url https://download.pytorch.org/whl/cpu -r /tmp/req-torch.txt; \
        pip install -r /tmp/req-rest.txt pytest; \
    else \
        pip install -r /tmp/req-clean.txt pytest; \
    fi; \
    rm -f /tmp/req-clean.txt /tmp/req-torch.txt /tmp/req-rest.txt

# Copy flattened quant_nn_engine package directly into /worker/quant_nn_engine
COPY src/quant_nn_engine ./quant_nn_engine

# Copy worker adapter & entrypoint
COPY src/quant_nn_worker/ ./
CMD ["python", "main.py"]
