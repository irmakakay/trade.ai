# Testing & CI/CD Standards
1. Maintain >=80% line coverage in `.NET` (`Coverlet`) and >=85% in Python (`pytest-cov`).
2. Keep `schema_parity_test` passing so C# `QuantCore.Contracts` and Python `adapter/schemas.py` never drift.
