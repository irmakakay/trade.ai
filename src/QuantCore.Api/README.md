# QuantCore.Api (.NET 8 State Manager, Lock Coordinator & Stream Gateway)
- Owns PostgreSQL connection pool, `FOR UPDATE SKIP LOCKED` strategy pool checkouts, and millisecond symbol/USDT slice reservations.
- Publishes NN jobs to `input_queue` and peeks single-head `output_queue` (`x-max-length: 1`).
- Multiplexes live market ticks + agent execution markers over `/api/v1/stream/live` WebSocket to the embedded React UI.
