# QuantCore: Autonomous $0-Cost Crypto Dry-Run & Strategy Evolution Platform

## 1. System Overview
QuantCore is a high-performance, zero-subscription polyglot architecture designed for 8GB Apple Silicon (M1) + optional LAN GPU offload:
- **Zero-Cost Market Feeds**: Ingests historical archives (`data.binance.vision`) and live keyless WebSockets (`wss://stream.binance.com:9443/ws`) solely through `.NET 8 QuantCore.Api`.
- **Single-Slot Head-Swap Queue**: RabbitMQ `input_queue` (FIFO) + `output_queue` (`x-max-length: 1`, `x-overflow: drop-head`, with `size == 0` completion re-push fallback).
- **Database State & Self-Healing Concurrency**: PostgreSQL 16 stores `BYTEA` serialized PyTorch checkpoints, $K$-replicated $\pm\epsilon$ jittered strategy pools (`FOR UPDATE SKIP LOCKED`), and millisecond symbol/USDT slice mutexes with 5-second TTL self-healing.
- **Zero-Overhead Embedded UI**: React 18 + TradingView Lightweight Charts compiled into static assets served directly by Kestrel (`QuantCore.Api`) with 60fps canvas WebSocket updates.

## 2. Quickstart
```bash
cp .env.example .env
docker compose up --build
```
- **API & Live React Dashboard**: `http://localhost:8080`
- **Prometheus Metrics**: `http://localhost:8080/metrics`
- **RabbitMQ Management**: `http://localhost:15672`

## 3. LAN GPU Worker Offload (Optional)
To run `nn-worker` on a secondary GPU machine over LAN while keeping Postgres, RabbitMQ, and `.NET Api` on the primary laptop:
```bash
docker compose -f docker-compose.gpu-worker.yml up --build
```
