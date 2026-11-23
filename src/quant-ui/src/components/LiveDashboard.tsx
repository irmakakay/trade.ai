import React, { useEffect, useRef, useState } from "react";
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
    total_checkpoints?: number;
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
    strategy_payload?: string;
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

    let ws: WebSocket | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let isMounted = true;

    const connectWebSocket = () => {
      if (!isMounted) return;
      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      ws = new WebSocket(`${protocol}//${window.location.host}/api/v1/stream/live`);

      ws.onopen = () => {
        if (isMounted) setWsConnected(true);
      };

      ws.onclose = () => {
        if (!isMounted) return;
        setWsConnected(false);
        reconnectTimer = setTimeout(connectWebSocket, 2000);
      };

      ws.onerror = () => {
        ws?.close();
      };

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
          setEvents((prev) => [frame, ...prev.slice(0, 49)]);
          if (frame.event_type === "EPISODE_COMMITTED") {
            fetchSummary();
          }
        }
      };
    };

    connectWebSocket();

    return () => {
      isMounted = false;
      window.removeEventListener("resize", handleResize);
      if (reconnectTimer) clearTimeout(reconnectTimer);
      ws?.close();
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
            {kpis?.total_checkpoints ?? summary?.nn_checkpoints?.length ?? 0} Checkpoints
          </div>
        </div>
      </div>

      <div ref={chartContainerRef} style={{ borderRadius: "10px", overflow: "hidden", border: "1px solid #1e293b", marginBottom: "16px" }} />

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

        <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "14px", display: "flex", flexDirection: "column", justifyContent: "space-between" }}>
          <div>
            <h3 style={{ margin: "0 0 8px 0", fontSize: "14px", color: "#e2e8f0" }}>PyTorch NN Checkpoints & Strategy Pool Status</h3>
            <div style={{ maxHeight: "125px", overflowY: "auto", fontSize: "12px", fontFamily: "ui-monospace, monospace" }}>
              {(summary?.nn_checkpoints ?? []).map((cp, i) => (
                <div key={i} style={{ padding: "4px 0", borderBottom: "1px solid #1e293b", display: "flex", justifyContent: "space-between" }}>
                  <span style={{ color: "#c084fc", fontWeight: 600 }}>{cp.version_tag}</span>
                  <span style={{ color: "#e2e8f0" }}>Conf: {(Number(cp.confidence_score) * 100).toFixed(1)}%</span>
                  <span style={{ color: cp.is_promoted_live ? "#4ade80" : "#facc15", fontWeight: 700 }}>
                    {cp.is_promoted_live ? "PROMOTED" : "SHADOW"}
                  </span>
                </div>
              ))}
            </div>
          </div>
          <div style={{ marginTop: "8px", paddingTop: "8px", borderTop: "1px solid #334155", fontSize: "11px", fontFamily: "ui-monospace, monospace" }}>
            <div style={{ color: "#94a3b8", fontWeight: 700, marginBottom: "4px" }}>LIVE EVOLVED STRATEGY POOL (SL / TP / SLICE):</div>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: "4px" }}>
              {(summary?.pool_state ?? []).slice(0, 18).map((s, idx) => {
                let meta = "";
                try {
                  if (s.strategy_payload) {
                    const p = JSON.parse(s.strategy_payload);
                    meta = `SL:${Number(p.stop_loss_atr).toFixed(2)} TP:${Number(p.take_profit_rr).toFixed(2)}`;
                  }
                } catch {}
                const isClaimed = s.status === "CLAIMED";
                return (
                  <div key={idx} style={{ background: "#060911", padding: "4px 6px", borderRadius: "4px", border: isClaimed ? "1px solid #38bdf8" : "1px solid #1e293b" }}>
                    <div style={{ color: isClaimed ? "#38bdf8" : "#cbd5e1", fontWeight: 700 }}>
                      {s.profile_key.slice(0, 4)}#{s.replica_index} <span style={{ color: isClaimed ? "#4ade80" : "#64748b" }}>{isClaimed ? "RUN" : "RDY"}</span>
                    </div>
                    <div style={{ color: "#94a3b8", fontSize: "10px" }}>{meta || `r=${s.risk_dial_r}`}</div>
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      </div>

      <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "14px" }}>
        <h3 style={{ margin: "0 0 8px 0", fontSize: "14px", color: "#e2e8f0" }}>
          Real-Time WebSocket Event Stream ({events.length} events buffered)
        </h3>
        <div style={{ maxHeight: "160px", overflowY: "auto", fontFamily: "ui-monospace, monospace", fontSize: "12px" }}>
          {events.length === 0 ? (
            <div style={{ color: "#64748b", padding: "8px 0" }}>
              {wsConnected ? "Connected — waiting for next agent checkout, slice lock, or episode commit..." : "Reconnecting to /api/v1/stream/live..."}
            </div>
          ) : (
            events.map((e, idx) => {
              const badgeColor =
                e.event_type === "EPISODE_COMMITTED" ? "#4ade80" :
                e.event_type === "AGENT_SLICE_LOCK" ? "#facc15" :
                e.event_type === "FORCE_EPISODE_RESET" ? "#f87171" : "#38bdf8";

              return (
                <div key={idx} style={{ padding: "4px 0", borderBottom: "1px solid #1e293b", color: "#cbd5e1" }}>
                  <span style={{ color: "#64748b", marginRight: "8px" }}>{new Date(e.timestamp_ms).toLocaleTimeString()}</span>
                  <span style={{ color: badgeColor, fontWeight: 700, marginRight: "8px" }}>[{e.event_type}]</span>
                  <span>{e.symbol} | Agent: {e.agent_id ? e.agent_id.slice(0, 8) + "..." : "SYS"} | {e.action} ({e.price})</span>
                </div>
              );
            })
          )}
        </div>
      </div>
    </div>
  );
};
