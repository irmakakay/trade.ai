# Binary State Codec (`quant_nn_engine.serialization`)
Serializes and deserializes `(model.state_dict(), optimizer.state_dict(), feature_scaler_stats, confidence_score, architecture_config)` into a single deterministic `bytes` buffer (`io.BytesIO`) ready for PostgreSQL `BYTEA` storage.
