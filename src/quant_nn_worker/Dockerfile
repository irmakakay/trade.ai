FROM python:3.11-slim
WORKDIR /worker

# Install worker & engine dependencies
COPY src/quant_nn_worker/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy flattened quant_nn_engine package directly into /worker/quant_nn_engine
COPY src/quant_nn_engine ./quant_nn_engine

# Copy worker adapter & entrypoint
COPY src/quant_nn_worker/ ./
ENV PYTHONPATH="/worker:/worker/quant_nn_engine"
CMD ["python", "main.py"]
