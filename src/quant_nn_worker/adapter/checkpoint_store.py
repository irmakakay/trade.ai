import io
import json
import torch

class PostgresCheckpointStore:
    def __init__(self, conn_str: str):
        self.conn_str = conn_str

    @staticmethod
    def serialize_to_bytes(model: torch.nn.Module, optimizer: torch.optim.Optimizer, scaler_dict: dict) -> tuple[bytes, bytes, bytes]:
        w_buf, o_buf, s_buf = io.BytesIO(), io.BytesIO(), io.BytesIO()
        torch.save(model.state_dict(), w_buf)
        torch.save(optimizer.state_dict(), o_buf)
        s_buf.write(json.dumps(scaler_dict).encode("utf-8"))
        return w_buf.getvalue(), o_buf.getvalue(), s_buf.getvalue()

    @staticmethod
    def deserialize_from_bytes(model: torch.nn.Module, optimizer: torch.optim.Optimizer, w_bytes: bytes, o_bytes: bytes, s_bytes: bytes) -> dict:
        model.load_state_dict(torch.load(io.BytesIO(w_bytes), weights_only=True))
        optimizer.load_state_dict(torch.load(io.BytesIO(o_bytes), weights_only=True))
        return json.loads(s_bytes.decode("utf-8"))
