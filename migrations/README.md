# Idempotent Database Migrations Service
Executes ordered `VXXX__*.sql` migrations under a PostgreSQL session-level advisory lock (`pg_advisory_lock(948271)`), verifying SHA-256 checksums and seeding initial `USDT_CASH` and default trading profiles.
