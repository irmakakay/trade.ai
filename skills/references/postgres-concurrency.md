# PostgreSQL Concurrency & Precision
1. All crypto quantities and `USDT_CASH` balances use `NUMERIC(28, 10)`.
2. Strategy Pool checkout must use `FOR UPDATE SKIP LOCKED` ordered by `replica_index ASC`.
3. Symbol mutex in `portfolio_inventory` must enforce self-healing TTL (`locked_by_agent IS NULL OR lock_expires_at < NOW()`), reserve partial slice percentage, and set `locked_by_agent = NULL` in the same transaction.
