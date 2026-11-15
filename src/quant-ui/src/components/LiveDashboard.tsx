import React, { useEffect, useRef, useState } from 'react';
import { createChart, ISeriesApi } from 'lightweight-charts';

export const LiveDashboard: React.FC = () => {
  const chartContainerRef = useRef<HTMLDivElement | null>(null);
  const seriesRef = useRef<ISeriesApi<'Line'> | null>(null);
  const [recentEvents, setRecentEvents] = useState<string[]>([]);

  useEffect(() => {
    if (!chartContainerRef.current) return;
    const chart = createChart(chartContainerRef.current, {
      width: chartContainerRef.current.clientWidth,
      height: 360,
      layout: { background: { color: '#111622' }, textColor: '#c9d1d9' },
      grid: { vertLines: { color: '#1f2937' }, horzLines: { color: '#1f2937' } }
    });
    seriesRef.current = chart.addLineSeries({ color: '#38bdf8', lineWidth: 2 });

    const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(`${proto}://${window.location.host}/api/v1/stream/live`);

    ws.onmessage = (evt) => {
      const frame = JSON.parse(evt.data);
      if (frame.event_type === 'MARKET_TICK' && seriesRef.current) {
        seriesRef.current.update({
          time: Math.floor(frame.timestamp_ms / 1000) as any,
          value: frame.price
        });
      } else {
        setRecentEvents((prev) => [
          `[${frame.event_type}] ${frame.symbol} | Agent: ${frame.agent_id ?? 'N/A'} | ${frame.action ?? ''} (${frame.price})`,
          ...prev.slice(0, 19)
        ]);
      }
    };

    return () => {
      ws.close();
      chart.remove();
    };
  }, []);

  return (
    <div style={{ padding: '20px', maxWidth: '1200px', margin: '0 auto' }}>
      <h2 style={{ marginTop: 0 }}>QuantCore Live Market & Agent Swarm Telemetry</h2>
      <div ref={chartContainerRef} style={{ borderRadius: '8px', overflow: 'hidden', border: '1px solid #1f2937' }} />
      <h3 style={{ marginTop: '24px' }}>Live Agent Pool Checkouts & Share-Slice Locks</h3>
      <pre style={{ background: '#111622', padding: '14px', borderRadius: '8px', minHeight: '180px' }}>
        {recentEvents.length === 0 ? 'Waiting for stream events...' : recentEvents.join('\n')}
      </pre>
    </div>
  );
};
