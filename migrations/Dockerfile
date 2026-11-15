FROM python:3.11-slim
WORKDIR /migrations
RUN pip install --no-cache-dir psycopg[binary]
COPY runner.py .
COPY versions/ ./versions/
CMD ["python", "runner.py"]
