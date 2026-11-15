# React 18 Real-Time Canvas UI Practices
1. Never store high-frequency tick updates in React `useState`.
2. Route WebSocket `MARKET_TICK` and `AGENT_MOVE` frames directly into `useRef` instances bound to `lightweight-charts` canvas APIs (`seriesRef.current.update()`).
