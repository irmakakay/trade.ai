from typing import Dict
import torch
import torch.nn as nn


class DifferentiableNavSharpeLoss(nn.Module):
    """
    Optimizes future position NAV while penalizing drawdown and simulated crypto taker fees (10 bps).
    Also calibrates the confidence_score head against actual positive trade outcomes.
    """
    def __init__(self, fee_rate: float = 0.0010, drawdown_weight: float = 2.0):
        super().__init__()
        self.fee_rate = fee_rate
        self.drawdown_weight = drawdown_weight
        self.bce = nn.BCELoss()

    def forward(
        self,
        model_out: Dict[str, torch.Tensor],
        future_returns: torch.Tensor,
    ) -> torch.Tensor:
        probs = torch.softmax(model_out["action_logits"], dim=-1)
        # Net directional exposure: P(BUY) - P(SELL) scaled by target slice
        signed_position = (probs[:, 0] - probs[:, 1]) * model_out["target_slice_pct"]
        turnover = (probs[:, 0] + probs[:, 1]) * model_out["target_slice_pct"]

        net_pnl = signed_position * future_returns - (turnover * self.fee_rate)
        mean_pnl = torch.mean(net_pnl)
        std_pnl = torch.std(net_pnl, unbiased=False) + 1e-6
        sharpe_proxy = mean_pnl / std_pnl

        downside = torch.relu(-net_pnl)
        drawdown_penalty = torch.mean(downside ** 2) * self.drawdown_weight

        # Confidence calibration target: did the chosen directional sign make net profit?
        profitable_target = (net_pnl.detach() > 0.0).float()
        confidence_loss = self.bce(model_out["confidence_score"], profitable_target)

        return -sharpe_proxy + drawdown_penalty + 0.25 * confidence_loss
