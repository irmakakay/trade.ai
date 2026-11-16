from typing import Dict
import torch
import torch.nn as nn


class FiLMRiskConditioner(nn.Module):
    """Modulates hidden representation h using continuous risk dial r in [0.0, 1.0]."""
    def __init__(self, hidden_dim: int):
        super().__init__()
        self.proj = nn.Sequential(
            nn.Linear(1, hidden_dim * 2),
            nn.SiLU(),
            nn.Linear(hidden_dim * 2, hidden_dim * 2),
        )

    def forward(self, h: torch.Tensor, risk_r: torch.Tensor) -> torch.Tensor:
        gamma_beta = self.proj(risk_r)
        gamma, beta = torch.chunk(gamma_beta, 2, dim=-1)
        return h * (1.0 + torch.tanh(gamma)) + beta


class PortfolioConditionedQuantNet(nn.Module):
    def __init__(
        self,
        market_feature_dim: int = 10,
        portfolio_feature_dim: int = 6,
        hidden_dim: int = 64,
    ):
        super().__init__()
        self.market_feature_dim = market_feature_dim
        self.portfolio_feature_dim = portfolio_feature_dim
        self.hidden_dim = hidden_dim

        # Stream 1: Temporal Market Encoder (Conv1d + GRU)
        self.temporal_conv = nn.Conv1d(
            in_channels=market_feature_dim,
            out_channels=hidden_dim,
            kernel_size=3,
            padding=1,
        )
        self.temporal_gru = nn.GRU(
            input_size=hidden_dim,
            hidden_size=hidden_dim,
            num_layers=1,
            batch_first=True,
        )

        # Stream 2: Portfolio & History State Encoder
        self.portfolio_encoder = nn.Sequential(
            nn.Linear(portfolio_feature_dim, hidden_dim),
            nn.LayerNorm(hidden_dim),
            nn.GELU(),
        )

        # Fusion + Stream 3: Continuous Risk Dial Conditioning
        self.fusion = nn.Sequential(
            nn.Linear(hidden_dim * 2, hidden_dim),
            nn.LayerNorm(hidden_dim),
            nn.GELU(),
        )
        self.film_risk = FiLMRiskConditioner(hidden_dim)

        # Head 1: Strategy Hyperparameter Generator (4 bounded scalars)
        self.strategy_head = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim // 2),
            nn.GELU(),
            nn.Linear(hidden_dim // 2, 4),
            nn.Sigmoid(),
        )

        # Head 2: Move Forecast & Asset Suitability Head
        # Outputs: [buy_logit, sell_logit, hold_logit, target_slice_raw, suitability_raw]
        self.move_head = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim // 2),
            nn.GELU(),
            nn.Linear(hidden_dim // 2, 5),
        )

        # Head 3: Model Confidence & Calibration Gate
        self.confidence_head = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim // 2),
            nn.GELU(),
            nn.Linear(hidden_dim // 2, 1),
            nn.Sigmoid(),
        )

    def forward(
        self,
        market_seq: torch.Tensor,
        portfolio_vec: torch.Tensor,
        risk_r: torch.Tensor,
    ) -> Dict[str, torch.Tensor]:
        """
        market_seq: (B, T, F_m)
        portfolio_vec: (B, F_p)
        risk_r: (B, 1) in [0.0, 1.0]
        """
        x_conv = torch.nn.functional.gelu(self.temporal_conv(market_seq.transpose(1, 2))).transpose(1, 2)
        _, h_n = self.temporal_gru(x_conv)
        market_emb = h_n.squeeze(0)

        port_emb = self.portfolio_encoder(portfolio_vec)
        fused = self.fusion(torch.cat([market_emb, port_emb], dim=-1))
        conditioned = self.film_risk(fused, risk_r)

        strat_raw = self.strategy_head(conditioned)
        r_flat = risk_r.squeeze(-1)

        # Risk-aware parameter interpolation anchored by neural network output
        entry_threshold = 0.45 + (1.0 - r_flat) * 0.35 + strat_raw[:, 0] * 0.12
        stop_loss_atr = 0.80 + r_flat * 1.60 + strat_raw[:, 1] * 0.40
        take_profit_rr = 1.15 + r_flat * 2.50 + strat_raw[:, 2] * 0.50
        max_slice_pct = 0.10 + r_flat * 0.40 + strat_raw[:, 3] * 0.15

        move_out = self.move_head(conditioned)
        action_logits = move_out[:, :3]
        target_slice_pct = torch.sigmoid(move_out[:, 3]) * max_slice_pct
        suitability_score = torch.sigmoid(move_out[:, 4])

        confidence = self.confidence_head(conditioned).squeeze(-1)

        return {
            "entry_threshold": torch.clamp(entry_threshold, 0.05, 0.95),
            "stop_loss_atr": torch.clamp(stop_loss_atr, 0.2, 10.0),
            "take_profit_rr": torch.clamp(take_profit_rr, 0.5, 15.0),
            "max_slice_claim_pct": torch.clamp(max_slice_pct, 0.05, 0.95),
            "action_logits": action_logits,
            "target_slice_pct": target_slice_pct,
            "suitability_score": suitability_score,
            "confidence_score": confidence,
        }
