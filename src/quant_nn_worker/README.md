# quant_nn_worker (Python AMQP Adapter + Isolated PyTorch Brain)
- `adapter/`: Consumes `input_queue`, updates `output_queue` (`x-max-length: 1`, `drop-head`) with `size == 0` terminal status re-push guarantee, and persists `BYTEA` checkpoints + $K$-replicated jittered strategies into PostgreSQL.
- `brain/`: Pure PyTorch & NumPy strategy generator and antithetic $\pm\epsilon$ jitter engine with zero DB/AMQP imports.
