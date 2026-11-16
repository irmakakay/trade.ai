# Evolution & Population Exploration Submodule (`quant_nn_engine.evolution`)
- `jitter_pool.py`: Generates $K$ strategy replicas with Replica #1 as the exact Anchor (`0.0` jitter) and Replicas $2..K$ as antithetic $\pm\epsilon$ explorers.
- `empirical_gradient.py`: Consumes the completed `TradingHistory` records of all $K$ replicas from the previous run, computes risk-adjusted fitness scores, marks the generation winner, and shifts the base strategy vector $\theta$ along the empirical gradient.
