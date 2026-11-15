# Architecture Invariants
1. **Single Data Gateway**: Only `QuantCore.Api` connects to external Binance WebSockets/archives and Postgres locks.
2. **Queue State Law**: `input_queue` is FIFO (`prefetch_count=1`). `output_queue` enforces `x-max-length: 1` and `x-overflow: drop-head` with a fallback check: if `message_count == 0` after terminal transition, re-publish terminal status.
3. **Adapter vs. Brain Separation**: `src/quant_nn_worker/brain/` must have ZERO database or AMQP imports.
