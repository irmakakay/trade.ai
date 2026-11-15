# Python & PyTorch Practices (8GB M1 Target)
1. Stream batches via Python generator expressions (`yield`); never materialize full multi-year histories in eager lists.
2. Serialize PyTorch `state_dict()`, optimizer state, and feature scalers via `io.BytesIO` directly to Postgres `BYTEA`.
3. Enforce Pydantic v2 validation at the `adapter/schemas.py` boundary.
