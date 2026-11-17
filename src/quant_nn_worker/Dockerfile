FROM python:3.11-slim
WORKDIR /worker

# Install worker & engine dependencies
COPY src/quant_nn_worker/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Install isolated quant_nn_engine package
COPY src/quant_nn_engine /quant_nn_engine
RUN pip install --no-cache-dir -e /quant_nn_engine

# Copy worker adapter & entrypoint
COPY src/quant_nn_worker/ ./
CMD ["python", "main.py"]