python3 - << 'EOF'
from pathlib import Path

# 1. Add GET /api/v1/episodes/summary to AgentEpisodeEndpoints.cs
endpoints_path = Path("src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs")
code = endpoints_path.read_text(encoding="utf-8")

summary_endpoint = """
        app.MapGet("/api/v1/episodes/summary", async (Func<IDbConnection> dbFactory, CancellationToken ct) =>
        {
            using var conn = dbFactory();
            conn.Open();

            const string kpiSql = @"
                SELECT
                    COUNT(1) AS total_episodes,
                    COALESCE(SUM(realized_pnl_usdt), 0) AS total_pnl_usdt,
                    COALESCE(AVG(sharpe_estimate), 0) AS avg_sharpe,
                    COALESCE(MAX(max_drawdown_pct), 0) AS worst_drawdown_pct
                FROM trading_history;";

            var kpis = await conn.QuerySingleAsync(new CommandDefinition(kpiSql, cancellationToken: ct));

            const string recentEpisodesSql = @"
                SELECT run_id, profile_key, replica_index, realized_pnl_usdt, max_drawdown_pct, sharpe_estimate, completed_at
                FROM trading_history
                ORDER BY completed_at DESC
                LIMIT 15;";

            var recentEpisodes = await conn.QueryAsync(new CommandDefinition(recentEpisodesSql, cancellationToken: ct));

            const string nnCheckpointsSql = @"
                SELECT model_id, version_tag, confidence_score, is_promoted_live, created_at
                FROM nn_model_checkpoints
                ORDER BY created_at DESC
                LIMIT 8;";

            var checkpoints = await conn.QueryAsync(new CommandDefinition(nnCheckpointsSql, cancellationToken: ct));

            const string poolStateSql = @"
                SELECT profile_key, replica_index, status, risk_dial_r
                FROM strategy_pool
                ORDER BY profile_key, replica_index;";

            var poolState = await conn.QueryAsync(new CommandDefinition(poolStateSql, cancellationToken: ct));

            return Results.Ok(new
            {
                kpis,
                recent_episodes = recentEpisodes,
                nn_checkpoints = checkpoints,
                pool_state = poolState
            });
        });
"""

if "/api/v1/episodes/summary" not in code:
    code = code.replace("        return app;\n    }\n}", summary_endpoint + "\n        return app;\n    }\n}")
    endpoints_path.write_text(code, encoding="utf-8")
    print("[OK] Added GET /api/v1/episodes/summary to AgentEpisodeEndpoints.cs")

# 2. Write upgraded LiveDashboard.tsx with Earnings Ledger & NN Training Panel
dashboard_path = Path("src/quant-ui/src/components/LiveDashboard.tsx")
dashboard_path.write_text("""import React, { useEffect, useRef, useState } from "react";
import { createChart, IChartApi, ISeriesApi, LineData, Time } from "lightweight-charts";

interface StreamFrame {
  event_type: string;
  symbol: string;
  price: number;
  agent_id?: string;
  action?: string;
  timestamp_ms: number;
}

interface SummaryData {
  kpis: {
    total_episodes: number;
    total_pnl_usdt: number;
    avg_sharpe: number;
    worst_drawdown_pct: number;
  };
  recent_episodes: Array<{
    run_id: string;
    profile_key: string;
    replica_index: number;
    realized_pnl_usdt: number;
    max_drawdown_pct: number;
    sharpe_estimate: number;
    completed_at: string;
  }>;
  nn_checkpoints: Array<{
    model_id: string;
    version_tag: string;
    confidence_score: number;
    is_promoted_live: boolean;
    created_at: string;
  }>;
  pool_state: Array<{
    profile_key: string;
    replica_index: number;
    status: string;
    risk_dial_r: number;
  }>;
}

const SYMBOLS = ["SOLUSDT", "ETHUSDT", "BTCUSDT"] as const;

export const LiveDashboard: React.FC = () => {
  const chartContainerRef = useRef<HTMLDivElement | null>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const seriesRef = useRef<ISeriesApi<"Line"> | null>(null);

  const [selectedSymbol, setSelectedSymbol] = useState<string>("SOLUSDT");
  const selectedSymbolRef = useRef<string>("SOLUSDT");
  selectedSymbolRef.current = selectedSymbol;

  const historyBySymbol = useRef<Record<string, LineData[]>>({
    SOLUSDT: [],
    ETHUSDT: [],
    BTCUSDT: [],
  });

  const [latestPrices, setLatestPrices] = useState<Record<string, number>>({});
  const [wsConnected, setWsConnected] = useState<boolean>(false);
  const [events, setEvents] = useState<StreamFrame[]>([]);
  const [summary, setSummary] = useState<SummaryData | null>(null);

  const fetchSummary = async () => {
    try {
      const res = await fetch("/api/v1/episodes/summary");
      if (res.ok) {
        setSummary(await res.json());
      }
    } catch {
      // ignore transient network error
    }
  };

  useEffect(() => {
    fetchSummary();
    const timer = setInterval(fetchSummary, 2500);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    if (!chartContainerRef.current) return;

    const chart = createChart(chartContainerRef.current, {
      width: chartContainerRef.current.clientWidth,
      height: 300,
      layout: { background: { color: "#0b0f19" }, textColor: "#94a3b8" },
      grid: { vertLines: { color: "#1e293b" }, horzLines: { color: "#1e293b" } },
      rightPriceScale: { borderColor: "#334155" },
      timeScale: { timeVisible: true, secondsVisible: true, borderColor: "#334155" },
    });

    const lineSeries = chart.addLineSeries({ color: "#38bdf8", lineWidth: 2 });
    chartRef.current = chart;
    seriesRef.current = lineSeries;

    const handleResize = () => {
      if (chartContainerRef.current && chartRef.current) {
        chartRef.current.applyOptions({ width: chartContainerRef.current.clientWidth });
      }
    };
    window.addEventListener("resize", handleResize);

    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(`${protocol}//${window.location.host}/api/v1/stream/live`);

    ws.onopen = () => setWsConnected(true);
    ws.onclose = () => setWsConnected(false);

    ws.onmessage = (evt) => {
      const frame: StreamFrame = JSON.parse(evt.data);
      const tSec = Math.floor(frame.timestamp_ms / 1000) as Time;

      if (frame.event_type === "MARKET_TICK" && frame.price > 0) {
        setLatestPrices((prev) => ({ ...prev, [frame.symbol]: frame.price }));
        const arr = historyBySymbol.current[frame.symbol] ?? [];
        if (arr.length === 0 || (tSec as number) > (arr[arr.length - 1].time as number)) {
          arr.push({ time: tSec, value: frame.price });
        } else {
          arr[arr.length - 1] = { time: arr[arr.length - 1].time, value: frame.price };
        }
        historyBySymbol.current[frame.symbol] = arr.slice(-300);

        if (frame.symbol === selectedSymbolRef.current && seriesRef.current) {
          seriesRef.current.update(arr[arr.length - 1]);
        }
      } else {
        setEvents((prev) => [frame, ...prev.slice(0, 39)]);
        if (frame.event_type === "EPISODE_COMMITTED") {
          fetchSummary();
        }
      }
    };

    return () => {
      window.removeEventListener("resize", handleResize);
      ws.close();
      chart.remove();
    };
  }, []);

  useEffect(() => {
    if (!seriesRef.current) return;
    seriesRef.current.setData(historyBySymbol.current[selectedSymbol] ?? []);
    chartRef.current?.timeScale().fitContent();
  }, [selectedSymbol]);

  const kpis = summary?.kpis;
  const totalPnl = Number(kpis?.total_pnl_usdt ?? 0);

  return (
    <div style={{ background: "#060911", minHeight: "100vh", color: "#f8fafc", padding: "20px", fontFamily: "Inter, system-ui, sans-serif" }}>
      {/* Header */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "16px" }}>
        <div>
          <h2 style={{ margin: 0, fontSize: "20px", fontWeight: 700 }}>QuantCore Telemetry, Earnings Ledger & PyTorch NN Evolution</h2>
          <span style={{ fontSize: "12px", color: "#64748b" }}>Click any asset tab below to isolate its live price scale</span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: "8px", background: "#0f172a", padding: "6px 14px", borderRadius: "999px", border: "1px solid #1e293b" }}>
          <span style={{ width: 9, height: 9, borderRadius: "50%", background: wsConnected ? "#22c55e" : "#ef4444" }} />
          <span style={{ fontSize: "12px", fontWeight: 600, color: wsConnected ? "#4ade80" : "#f87171" }}>
            {wsConnected ? "WS STREAM LIVE" : "RECONNECTING"}
          </span>
        </div>
      </div>

      {/* Top Row: 3 Asset Selector Tabs + 3 Earnings/NN KPI Cards */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(6, 1fr)", gap: "10px", marginBottom: "16px" }}>
        {SYMBOLS.map((sym) => {
          const active = selectedSymbol === sym;
          const p = latestPrices[sym];
          return (
            <button
              key={sym}
              onClick={() => setSelectedSymbol(sym)}
              style={{
                textAlign: "left",
                cursor: "pointer",
                background: active ? "#1e293b" : "#0f172a",
                border: active ? "2px solid #38bdf8" : "1px solid #1e293b",
                borderRadius: "10px",
                padding: "12px",
                color: "#f8fafc",
              }}
            >
              <div style={{ fontSize: "11px", color: "#94a3b8", fontWeight: 600 }}>{sym} {active ? "• VIEWING" : ""}</div>
              <div style={{ fontSize: "18px", fontWeight: 700, marginTop: "4px", color: active ? "#38bdf8" : "#e2e8f0" }}>
                {p ? `$${p.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}` : "..."}
              </div>
            </button>
          );
        })}

        <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "12px" }}>
          <div style={{ fontSize: "11px", color: "#94a3b8", fontWeight: 600 }}>TOTAL REALIZED PNL</div>
          <div style={{ fontSize: "18px", fontWeight: 700, marginTop: "4px", color: totalPnl >= 0 ? "#4ade80" : "#f87171" }}>
            {totalPnl >= 0 ? "+" : ""}${totalPnl.toFixed(4)} USDT
          </div>
        </div>

        <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "12px" }}>
          <div style={{ fontSize: "11px", color: "#94a3b8", fontWeight: 600 }}>AVG SHARPE / EPISODES</div>
          <div style={{ fontSize: "18px", fontWeight: 700, marginTop: "4px", color: "#fbbf24" }}>
            {Number(kpis?.avg_sharpe ?? 0).toFixed(2)} <span style={{ fontSize: "12px", color: "#64748b" }}>({kpis?.total_episodes ?? 0} runs)</span>
          </div>
        </div>

        <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "12px" }}>
          <div style={{ fontSize: "11px", color: "#94a3b8", fontWeight: 600 }}>NN GENERATIONS TRAINED</div>
          <div style={{ fontSize: "18px", fontWeight: 700, marginTop: "4px", color: "#c084fc" }}>
            {summary?.nn_checkpoints?.length ?? 0} Checkpoints
          </div>
        </div>
      </div>

      {/* Isolated Symbol Price Chart */}
      <div ref={chartContainerRef} style={{ borderRadius: "10px", overflow: "hidden", border: "1px solid #1e293b", marginBottom: "16px" }} />

      {/* Middle Grid: Completed Episode Earnings Ledger + NN Evolution Checkpoints */}
      <div style={{ display: "grid", gridTemplateColumns: "1.4fr 1fr", gap: "16px", marginBottom: "16px" }}>
        <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "14px" }}>
          <h3 style={{ margin: "0 0 10px 0", fontSize: "14px", color: "#e2e8f0" }}>Completed Agent Episodes & Realized Earnings (PostgreSQL trading_history)</h3>
          <div style={{ maxHeight: "200px", overflowY: "auto", fontSize: "12px", fontFamily: "ui-monospace, monospace" }}>
            <table style={{ width: "100%", borderCollapse: "collapse", textAlign: "left" }}>
              <thead>
                <tr style={{ borderBottom: "1px solid #334155", color: "#94a3b8" }}>
                  <th style={{ padding: "6px" }}>Profile</th>
                  <th style={{ padding: "6px" }}>Replica</th>
                  <th style={{ padding: "6px" }}>PnL (USDT)</th>
                  <th style={{ padding: "6px" }}>Sharpe</th>
                  <th style={{ padding: "6px" }}>Max DD</th>
                </tr>
              </thead>
              <tbody>
                {(summary?.recent_episodes ?? []).map((ep, i) => {
                  const pnl = Number(ep.realized_pnl_usdt);
                  return (
                    <tr key={i} style={{ borderBottom: "1px solid #1e293b" }}>
                      <td style={{ padding: "6px", color: "#e2e8f0" }}>{ep.profile_key}</td>
                      <td style={{ padding: "6px", color: "#38bdf8" }}>#{ep.replica_index}</td>
                      <td style={{ padding: "6px", fontWeight: 700, color: pnl >= 0 ? "#4ade80" : "#f87171" }}>
                        {pnl >= 0 ? "+" : ""}{pnl.toFixed(4)}
                      </td>
                      <td style={{ padding: "6px", color: "#fbbf24" }}>{Number(ep.sharpe_estimate).toFixed(2)}</td>
                      <td style={{ padding: "6px", color: "#94a3b8" }}>{(Number(ep.max_drawdown_pct) * 100).toFixed(2)}%</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>

        <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "14px" }}>
          <h3 style={{ margin: "0 0 10px 0", fontSize: "14px", color: "#e2e8f0" }}>PyTorch NN Checkpoints & Strategy Pool Status</h3>
          <div style={{ maxHeight: "200px", overflowY: "auto", fontSize: "12px", fontFamily: "ui-monospace, monospace" }}>
            {(summary?.nn_checkpoints ?? []).map((cp, i) => (
              <div key={i} style={{ padding: "6px 0", borderBottom: "1px solid #1e293b", display: "flex", justifyContent: "space-between" }}>
                <span style={{ color: "#c084fc", fontWeight: 600 }}>{cp.version_tag}</span>
                <span style={{ color: "#e2e8f0" }}>Conf: {(Number(cp.confidence_score) * 100).toFixed(1)}%</span>
                <span style={{ color: cp.is_promoted_live ? "#4ade80" : "#facc15" }}>
                  {cp.is_promoted_live ? "PROMOTED" : "SHADOW"}
                </span>
              </div>
            ))}
            <div style={{ marginTop: "10px", paddingTop: "6px", borderTop: "1px solid #334155", color: "#94a3b8" }}>
              Active Pool Slots: {(summary?.pool_state ?? []).map((s) => `${s.profile_key.slice(0, 4)}#${s.replica_index}:${s.status}`).join(" | ")}
            </div>
          </div>
        </div>
      </div>

      {/* Bottom Live WebSocket Event Log */}
      <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "14px" }}>
        <h3 style={{ margin: "0 0 8px 0", fontSize: "14px", color: "#e2e8f0" }}>Real-Time WebSocket Event Stream</h3>
        <div style={{ maxHeight: "150px", overflowY: "auto", fontFamily: "ui-monospace, monospace", fontSize: "12px" }}>
          {events.map((e, idx) => (
            <div key={idx} style={{ padding: "4px 0", borderBottom: "1px solid #1e293b", color: "#cbd5e1" }}>
              [{e.event_type}] {e.symbol} | Agent: {e.agent_id ?? "SYS"} | {e.action} ({e.price})
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};
""", encoding="utf-8")
print("[OK] Wrote upgraded LiveDashboard.tsx with Earnings Ledger & NN Checkpoints")
EOF