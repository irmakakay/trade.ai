from typing import Dict
import torch
import torch.nn as nn


class DifferentiableNavSharpeLoss(nn.Module):
    """
    Optimizes future position NAV while penalizing drawdown and Revolut X taker fee ceiling (9 bps).
    Includes std floor and Sharpe clamp to prevent gradient explosions on tight replica batches.
    """
    def __init__(self, fee_rate: float = 0.0009, drawdown_weight: float = 2.0):
        super().__init__()
        self.fee_rate = fee_rate
        self.drawdown_weight = drawdown_weight
        self.bce = nn.BCELoss()

    def forward(
        self,
        model_out: Dict[str, torch.Tensor],
        future_returns: torch.Tensor,
        target_confidence: torch.Tensor | None = None,
    ) -> torch.Tensor:
        probs = torch.softmax(model_out["action_logits"], dim=-1)
        signed_position = (probs[:, 0] - probs[:, 1]) * model_out["target_slice_pct"]
        turnover = (probs[:, 0] + probs[:, 1]) * model_out["target_slice_pct"]

        net_pnl = signed_position * future_returns - (turnover * self.fee_rate)
        mean_pnl = torch.mean(net_pnl)

        if net_pnl.numel() > 1:
            std_pnl = torch.std(net_pnl, unbiased=False) + 1e-2
        else:
            std_pnl = torch.abs(mean_pnl).detach() + 1e-2

        sharpe_proxy = torch.clamp(mean_pnl / std_pnl, -5.0, 5.0)
        downside = torch.relu(-net_pnl)
        drawdown_penalty = torch.mean(downside ** 2) * self.drawdown_weight

        if target_confidence is None:
            target_confidence = torch.clamp(torch.sigmoid(future_returns * 25.0 + 0.6), 0.15, 0.92).detach()

        confidence_loss = self.bce(model_out["confidence_score"], target_confidence)
        return -sharpe_proxy + drawdown_penalty + 0.50 * confidence_loss
