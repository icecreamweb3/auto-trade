import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type HealthStatus = "HEALTHY" | "WARNING" | "CRITICAL" | "UNKNOWN";

interface CoverageMetric {
  key: string;
  label: string;
  status: HealthStatus;
  latest_at: string | null;
  age_seconds: number | null;
  expected_symbols: number;
  actual_symbols: number;
  websocket_symbols: number | null;
  completeness_percent: number;
  message: string;
}

interface MonitoringSnapshot {
  generated_at: string;
  environment: string;
  node_id: string;
  overall_status: HealthStatus;
  active_symbols: number;
  coverage: CoverageMetric[];
  websocket_sync: Array<{
    key: string;
    label: string;
    status: HealthStatus;
    window_minutes: number;
    expected: number;
    succeeded: number;
    failed: number;
    rest_fallback: number;
    other_source: number;
    missing: number;
    success_percent: number;
  }>;
  backfill: {
    status: HealthStatus;
    counts: Record<string, number>;
    open_gaps: number;
    oldest_pending_seconds: number | null;
    succeeded_last_hour: number;
    created_last_hour: number;
    finished_last_hour: number;
    queue_delta_last_hour: number;
    estimated_clear_seconds: number | null;
    last_succeeded_at: string | null;
    pending_range_start: string | null;
    pending_range_end: string | null;
    running_jobs: Array<{
      symbol: string;
      data_type: string;
      interval_seconds: number;
      range_start: string;
      range_end: string;
      started_at: string | null;
      attempts: number;
    }>;
    message: string;
  };
  rest_usage: {
    status: HealthStatus;
    request_rate_1m: number | null;
    used_weight_1m: number | null;
    limit_1m: number;
    utilization_percent: number | null;
    average_used_weight_1h: number | null;
    average_utilization_percent_1h: number | null;
    sampled_minutes_1h: number;
    observed_at: string | null;
    message: string;
  };
  nats: {
    status: HealthStatus;
    connected: boolean;
    streams: Array<{ name: string; messages: number; bytes: number; consumers: number }>;
    message: string;
  };
  database: {
    status: HealthStatus;
    size_bytes: number;
    size_display: string;
    cache_hit_percent: number | null;
    largest_tables: Array<{
      schema_name: string;
      table_name: string;
      is_hypertable: boolean;
      estimated_rows: number;
      table_bytes: number;
      index_bytes: number;
      toast_bytes: number;
      total_bytes: number;
      chunk_count: number | null;
      compression_enabled: boolean | null;
      columnstore_chunks: number;
      columnstore_before_bytes: number;
      columnstore_after_bytes: number;
      columnstore_saved_percent: number | null;
      columnstore_policy_enabled: boolean;
    }>;
    message: string;
  };
  notices: string[];
}

interface RankingEntry {
  utc_trade_date: string;
  snapshot_at: string;
  rank_no: number;
  symbol: string;
  price_change: number;
  reference_open_price: number | null;
  snapshot_price: number | null;
  base_volume: number | null;
  quote_volume: number | null;
  amplitude: number | null;
  period_high_price: number | null;
  period_high_at: string | null;
  period_low_price: number | null;
  period_low_at: string | null;
  open_interest_qty: number | null;
  open_interest_value: number | null;
  open_interest_status: string;
  quality_status: string;
}

interface RankingResult {
  available_first_date: string | null;
  available_last_date: string | null;
  date_from: string | null;
  date_to: string | null;
  symbol: string | null;
  rank_from: number;
  rank_to: number;
  page: number;
  page_size: number;
  total: number;
  matching_days: number;
  average_change: number | null;
  maximum_change: number | null;
  minimum_change: number | null;
  items: RankingEntry[];
}

interface KlinePoint {
  open_time: string;
  close_time: string;
  open_price: number;
  high_price: number;
  low_price: number;
  close_price: number;
  base_volume: number;
  quote_volume: number;
  open_interest_qty: number | null;
  open_interest_value: number | null;
  ema20: number;
  ema240: number;
}

interface DailyKlineResult {
  symbol: string;
  utc_trade_date: string;
  price_type: string;
  interval_seconds: number;
  items: KlinePoint[];
}

interface KlineHistoryResult {
  symbol: string;
  price_type: string;
  interval_seconds: number;
  has_more: boolean;
  items: KlinePoint[];
}

interface RankingFilters {
  dateFrom: string;
  dateTo: string;
  symbol: string;
  rankFrom: number;
  rankTo: number;
}

const statusText: Record<HealthStatus, string> = {
  HEALTHY: "健康",
  WARNING: "注意",
  CRITICAL: "异常",
  UNKNOWN: "等待数据"
};

function StatusPill({ status }: { status: HealthStatus }) {
  return <span className={`status status-${status.toLowerCase()}`}>{statusText[status]}</span>;
}

function formatUtc(value: string | null): string {
  if (!value) return "—";
  return `${new Date(value).toISOString().replace("T", " ").slice(0, 19)} UTC`;
}

function formatAge(seconds: number | null): string {
  if (seconds === null) return "—";
  if (seconds < 60) return `${Math.round(seconds)} 秒`;
  if (seconds < 3600) return `${Math.round(seconds / 60)} 分钟`;
  return `${(seconds / 3600).toFixed(1)} 小时`;
}

function formatUtcRange(start: string | null, end: string | null): string {
  if (!start || !end) return "—";
  const from = new Date(start).toISOString().replace("T", " ").slice(0, 16);
  const to = new Date(end).toISOString().replace("T", " ").slice(0, 16);
  return `${from} → ${to} UTC`;
}

const UTC8_OFFSET_MS = 8 * 60 * 60 * 1000;

function utc8Iso(value: string): string {
  return new Date(new Date(value).getTime() + UTC8_OFFSET_MS).toISOString();
}

function formatKlineTime(value: string, axis = false): string {
  const local = utc8Iso(value);
  const datePart = axis ? local.slice(5, 10) : local.slice(0, 10);
  return `${datePart} ${local.slice(11, 16)}${axis ? "" : " UTC+8"}`;
}

function formatKlineTradeWindow(utcTradeDate: string): string {
  const start = utc8Iso(`${utcTradeDate}T00:00:00Z`);
  const end = utc8Iso(`${utcTradeDate}T23:55:00Z`);
  return `${start.slice(0, 10)} ${start.slice(11, 16)} – ${end.slice(0, 10)} ${end.slice(11, 16)}`;
}

function formatRankingDataRange(firstDate: string | null, lastDate: string | null): string {
  if (!firstDate || !lastDate) return "—";
  const start = utc8Iso(`${firstDate}T00:00:00Z`);
  const end = utc8Iso(`${lastDate}T23:55:00Z`);
  return `${start.slice(0, 10)} ${start.slice(11, 16)} → ${end.slice(0, 10)} ${end.slice(11, 16)} UTC+8`;
}

function formatBackfillSeries(dataType: string, intervalSeconds: number): string {
  const type = dataType === "KLINE_MARK" ? "Mark K线" : "Trade K线";
  const interval = intervalSeconds % 60 === 0
    ? `${intervalSeconds / 60}m`
    : `${intervalSeconds}s`;
  return `${type} · ${interval}`;
}

function formatDelta(value: number): string {
  return value > 0 ? `+${value}` : value.toString();
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = units[0];
  for (const candidate of units) {
    unit = candidate;
    if (value < 1024 || candidate === units[units.length - 1]) break;
    value /= 1024;
  }
  return `${value.toFixed(value >= 100 ? 0 : value >= 10 ? 1 : 2)} ${unit}`;
}

function formatNumber(value: number | null, maximumFractionDigits = 4): string {
  if (value === null) return "—";
  return new Intl.NumberFormat("zh-CN", { maximumFractionDigits }).format(value);
}

function formatCompact(value: number | null): string {
  if (value === null) return "—";
  return new Intl.NumberFormat("zh-CN", {
    notation: "compact",
    maximumFractionDigits: 2
  }).format(value);
}

function changeClass(value: number): string {
  return value >= 0 ? "change-positive" : "change-negative";
}

function CoverageCard({ metric }: { metric: CoverageMetric }) {
  const width = Math.min(100, metric.completeness_percent);
  return (
    <article className="panel coverage-card">
      <div className="panel-heading">
        <div>
          <p className="eyebrow">数据覆盖</p>
          <h3>{metric.label}</h3>
        </div>
        <StatusPill status={metric.status} />
      </div>
      <div className="coverage-number">
        <strong>{metric.actual_symbols}</strong>
        <span>/ {metric.expected_symbols}</span>
      </div>
      <div className="progress"><span style={{ width: `${width}%` }} /></div>
      <dl className="detail-grid">
        <div><dt>完整率</dt><dd>{metric.completeness_percent.toFixed(2)}%</dd></div>
        <div><dt>延迟</dt><dd>{formatAge(metric.age_seconds)}</dd></div>
        <div><dt>WebSocket</dt><dd>{metric.websocket_symbols ?? "REST"}</dd></div>
        <div><dt>最新周期</dt><dd>{formatUtc(metric.latest_at)}</dd></div>
      </dl>
      <p className="message">{metric.message}</p>
    </article>
  );
}

function CandlestickChart({ data }: { data: DailyKlineResult }) {
  const [hoveredIndex, setHoveredIndex] = useState<number | null>(null);
  const [verticalZoom, setVerticalZoom] = useState(1);
  const desiredViewportCount = data.interval_seconds === 300 ? 112 : 64;
  const [allItems, setAllItems] = useState(data.items);
  const [hasMoreHistory, setHasMoreHistory] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(false);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const viewportCount = Math.min(allItems.length, desiredViewportCount);
  const [viewportStart, setViewportStart] = useState(() => Math.max(0, allItems.length - viewportCount));
  const dragRef = useRef<{ clientX: number; viewportStart: number } | null>(null);
  const chartRef = useRef<SVGSVGElement>(null);
  const loadingHistoryRef = useRef(false);
  const dataKeyRef = useRef(`${data.symbol}-${data.utc_trade_date}-${data.interval_seconds}`);
  dataKeyRef.current = `${data.symbol}-${data.utc_trade_date}-${data.interval_seconds}`;
  const maxViewportStart = Math.max(0, allItems.length - viewportCount);
  const points = allItems.slice(viewportStart, viewportStart + viewportCount);
  const hasOi = allItems.some((point) => point.open_interest_value !== null || point.open_interest_qty !== null);
  const width = 1100;
  const height = hasOi ? 650 : 560;
  const left = 76;
  const right = 90;
  const top = 28;
  const priceBottom = hasOi ? 350 : 398;
  const volumeTop = hasOi ? 386 : 434;
  const volumeBottom = hasOi ? 466 : 520;
  const oiTop = 510;
  const oiBottom = 610;
  const plotWidth = width - left - right;
  const priceHeight = priceBottom - top;
  const volumePlotHeight = volumeBottom - volumeTop;
  const low = Math.min(...points.flatMap((point) => [point.low_price, point.ema20, point.ema240]));
  const high = Math.max(...points.flatMap((point) => [point.high_price, point.ema20, point.ema240]));
  const rawRange = Math.max(high - low, Math.abs(high) * 0.001, 1e-12);
  const priceCenter = (low + high) / 2;
  const priceRange = rawRange * 1.12 / verticalZoom;
  const priceMin = priceCenter - priceRange / 2;
  const priceMax = priceCenter + priceRange / 2;
  const maxVolume = Math.max(...points.map((point) => point.quote_volume), 1);
  const oiValues = points
    .map((point) => point.open_interest_value ?? point.open_interest_qty)
    .filter((value): value is number => value !== null);
  const oiMin = oiValues.length > 0 ? Math.min(...oiValues) : 0;
  const oiMax = oiValues.length > 0 ? Math.max(...oiValues) : 1;
  const oiDataRange = Math.max(oiMax - oiMin, Math.abs(oiMax) * 0.001, 1e-12);
  const oiScaleMin = Math.max(0, oiMin - oiDataRange * 0.08);
  const oiScaleMax = oiMax + oiDataRange * 0.05;
  const oiRange = oiScaleMax - oiScaleMin;
  const candleSlot = plotWidth / points.length;
  const candleWidth = Math.max(2, Math.min(8, candleSlot * 0.68));
  const hovered = hoveredIndex === null ? points[points.length - 1] : points[hoveredIndex];
  const xAt = (index: number) => left + candleSlot * (index + 0.5);
  const yAt = (price: number) => top + (priceMax - price) / priceRange * priceHeight;
  const oiYAt = (value: number) => oiTop + (oiScaleMax - value) / oiRange * (oiBottom - oiTop);
  const priceTicks = Array.from({ length: 6 }, (_, index) => priceMax - priceRange * index / 5);
  const timeTicks = [0, Math.round((points.length - 1) / 4), Math.round((points.length - 1) / 2), Math.round((points.length - 1) * 3 / 4), points.length - 1]
    .filter((index, position, values) => index >= 0 && index < points.length && values.indexOf(index) === position);
  const ema20Path = points.map((point, index) => `${xAt(index)},${yAt(point.ema20)}`).join(" ");
  const ema240Path = points.map((point, index) => `${xAt(index)},${yAt(point.ema240)}`).join(" ");
  let previousOi: number | null = null;
  const oiBars = points.map((point, index) => {
    const value = point.open_interest_value ?? point.open_interest_qty;
    if (value === null) return null;
    const rising = previousOi === null || value >= previousOi;
    previousOi = value;
    return { index, value, rising };
  }).filter((bar): bar is { index: number; value: number; rising: boolean } => bar !== null);

  useEffect(() => {
    setAllItems(data.items);
    setViewportStart(Math.max(0, data.items.length - Math.min(data.items.length, desiredViewportCount)));
    setHasMoreHistory(true);
    setLoadingHistory(false);
    setHistoryError(null);
    loadingHistoryRef.current = false;
    setHoveredIndex(null);
    setVerticalZoom(1);
  }, [data, desiredViewportCount]);

  useEffect(() => {
    const chart = chartRef.current;
    if (!chart) return;
    const handleWheel = (event: WheelEvent) => {
      const bounds = chart.getBoundingClientRect();
      const svgY = (event.clientY - bounds.top) / bounds.height * height;
      if (svgY < top || svgY > priceBottom || event.deltaY === 0) return;
      event.preventDefault();
      const zoomFactor = Math.exp(-event.deltaY * 0.002);
      setVerticalZoom((current) => Math.max(0.25, Math.min(8, current * zoomFactor)));
    };
    chart.addEventListener("wheel", handleWheel, { passive: false });
    return () => chart.removeEventListener("wheel", handleWheel);
  }, [height, priceBottom]);

  function handlePointerMove(event: React.PointerEvent<SVGSVGElement>) {
    const bounds = event.currentTarget.getBoundingClientRect();
    if (dragRef.current) {
      const pixelsPerBar = bounds.width / viewportCount;
      const barsMoved = Math.round((event.clientX - dragRef.current.clientX) / pixelsPerBar);
      const nextStart = Math.max(0, Math.min(maxViewportStart, dragRef.current.viewportStart - barsMoved));
      setViewportStart(nextStart);
      if (nextStart <= 8) void loadEarlier();
      setHoveredIndex(null);
      return;
    }
    const svgX = (event.clientX - bounds.left) / bounds.width * width;
    const index = Math.max(0, Math.min(points.length - 1, Math.floor((svgX - left) / candleSlot)));
    setHoveredIndex(index);
  }

  function handlePointerDown(event: React.PointerEvent<SVGSVGElement>) {
    dragRef.current = { clientX: event.clientX, viewportStart };
    event.currentTarget.setPointerCapture(event.pointerId);
    if (viewportStart <= 8) void loadEarlier();
  }

  function handlePointerUp(event: React.PointerEvent<SVGSVGElement>) {
    dragRef.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  }

  async function loadEarlier() {
    if (loadingHistoryRef.current || !hasMoreHistory || allItems.length === 0) return;
    const requestKey = `${data.symbol}-${data.utc_trade_date}-${data.interval_seconds}`;
    const before = allItems[0].open_time;
    loadingHistoryRef.current = true;
    setLoadingHistory(true);
    setHistoryError(null);
    const params = new URLSearchParams({
      symbol: data.symbol,
      interval_seconds: String(data.interval_seconds),
      before,
      limit: "300"
    });
    try {
      const response = await fetch(`/api/market/klines/history?${params}`, { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const result = await response.json() as KlineHistoryResult;
      if (dataKeyRef.current !== requestKey) return;
      const earliest = new Date(allItems[0].open_time).getTime();
      const earlier = result.items.filter((item) => new Date(item.open_time).getTime() < earliest);
      if (earlier.length === 0) {
        setHasMoreHistory(false);
        return;
      }
      setAllItems([...earlier, ...allItems]);
      setViewportStart((currentStart) => currentStart + earlier.length);
      if (dragRef.current) dragRef.current.viewportStart += earlier.length;
      setHasMoreHistory(result.has_more);
    } catch {
      if (dataKeyRef.current === requestKey) {
        setHistoryError("更早K线加载失败，请再次拖动重试");
      }
    } finally {
      if (dataKeyRef.current === requestKey) {
        loadingHistoryRef.current = false;
        setLoadingHistory(false);
      }
    }
  }

  return <>
    <div className="chart-readout">
      <span>{formatKlineTime(hovered.open_time)}</span>
      <span>开 <strong>{formatNumber(hovered.open_price, 8)}</strong></span>
      <span>高 <strong>{formatNumber(hovered.high_price, 8)}</strong></span>
      <span>低 <strong>{formatNumber(hovered.low_price, 8)}</strong></span>
      <span>收 <strong className={changeClass(hovered.close_price - hovered.open_price)}>{formatNumber(hovered.close_price, 8)}</strong></span>
      <span className="ema20-label">EMA20 <strong>{formatNumber(hovered.ema20, 8)}</strong></span>
      <span className="ema240-label">EMA240 <strong>{formatNumber(hovered.ema240, 8)}</strong></span>
      <span>成交额 <strong>{formatCompact(hovered.quote_volume)}</strong></span>
      {(hovered.open_interest_value !== null || hovered.open_interest_qty !== null) && <span>OI{hovered.open_interest_value !== null ? "价值" : "数量"} <strong>{formatCompact(hovered.open_interest_value ?? hovered.open_interest_qty)}</strong></span>}
      <button type="button" className="chart-axis-reset" onClick={() => setVerticalZoom(1)} title="恢复自动纵轴">纵轴 {Math.round(verticalZoom * 100)}%</button>
      <span className={`chart-drag-hint${historyError ? " chart-history-error" : ""}`}>{loadingHistory ? "正在加载更早K线…" : historyError ?? (!hasMoreHistory && viewportStart === 0 ? "已到最早K线" : "向右拖动持续回溯")} · 主图滚轮缩放纵轴 · {viewportStart + 1}–{viewportStart + points.length} / {allItems.length}</span>
    </div>
    <svg
      ref={chartRef}
      className="candlestick-chart"
      viewBox={`0 0 ${width} ${height}`}
      role="img"
      aria-label={`${data.symbol} ${formatKlineTradeWindow(data.utc_trade_date)} UTC+8 ${data.interval_seconds / 60}分钟K线图`}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerUp}
      onPointerLeave={() => { if (!dragRef.current) setHoveredIndex(null); }}
    >
      <rect x="0" y="0" width={width} height={height} rx="10" className="chart-background" />
      {priceTicks.map((price) => {
        const y = yAt(price);
        return <g key={price}>
          <line x1={left} x2={width - right} y1={y} y2={y} className="chart-grid-line" />
          <text x={width - right + 10} y={y + 4} className="chart-axis-label">{formatNumber(price, 8)}</text>
        </g>;
      })}
      <line x1={left} x2={width - right} y1={volumeTop - 12} y2={volumeTop - 12} className="chart-divider" />
      <text x="14" y={volumeTop + 10} className="chart-axis-label">成交额</text>
      {points.map((point, index) => {
        const x = xAt(index);
        const openY = yAt(point.open_price);
        const closeY = yAt(point.close_price);
        const highY = yAt(point.high_price);
        const lowY = yAt(point.low_price);
        const rising = point.close_price >= point.open_price;
        const bodyTop = Math.min(openY, closeY);
        const bodyHeight = Math.max(1, Math.abs(closeY - openY));
        const barHeight = point.quote_volume / maxVolume * volumePlotHeight;
        const colorClass = rising ? "chart-up" : "chart-down";
        return <g key={point.open_time} className={colorClass}>
          <line x1={x} x2={x} y1={highY} y2={lowY} className="candle-wick" />
          <rect x={x - candleWidth / 2} y={bodyTop} width={candleWidth} height={bodyHeight} className="candle-body" />
          <rect x={x - candleWidth / 2} y={volumeBottom - barHeight} width={candleWidth} height={barHeight} className="volume-bar" />
        </g>;
      })}
      <polyline points={ema20Path} className="ema-line ema20-line" />
      <polyline points={ema240Path} className="ema-line ema240-line" />
      {timeTicks.map((index) => <text key={index} x={xAt(index)} y={height - 16} textAnchor="middle" className="chart-axis-label">
        {formatKlineTime(points[index].open_time, true)}
      </text>)}
      {hasOi && <>
        <line x1={left} x2={width - right} y1={oiTop - 18} y2={oiTop - 18} className="chart-divider" />
        <text x="14" y={oiTop + 10} className="chart-axis-label">OI{allItems.some((point) => point.open_interest_value !== null) ? "价值" : "数量"}</text>
        {oiBars.map((bar) => {
          const y = oiYAt(bar.value);
          return <rect
            key={points[bar.index].open_time}
            x={xAt(bar.index) - candleWidth / 2}
            y={y}
            width={candleWidth}
            height={Math.max(1, oiBottom - y)}
            className={bar.rising ? "oi-bar oi-bar-up" : "oi-bar oi-bar-down"}
          />;
        })}
        <text x={width - right + 10} y={oiTop + 4} className="chart-axis-label">{formatCompact(oiScaleMax)}</text>
        <text x={width - right + 10} y={oiBottom + 4} className="chart-axis-label">{formatCompact(oiScaleMin)}</text>
      </>}
      {hoveredIndex !== null && <g className="chart-crosshair">
        <line x1={xAt(hoveredIndex)} x2={xAt(hoveredIndex)} y1={top} y2={hasOi ? oiBottom : volumeBottom} />
        <line x1={left} x2={width - right} y1={yAt(points[hoveredIndex].close_price)} y2={yAt(points[hoveredIndex].close_price)} />
      </g>}
    </svg>
  </>;
}

function KlineModal({ entry, onClose }: { entry: RankingEntry; onClose: () => void }) {
  const [data, setData] = useState<DailyKlineResult | null>(null);
  const [intervalSeconds, setIntervalSeconds] = useState<300 | 900>(300);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    const params = new URLSearchParams({
      symbol: entry.symbol,
      utc_trade_date: entry.utc_trade_date,
      interval_seconds: String(intervalSeconds)
    });
    setLoading(true);
    setData(null);
    setError(null);
    void fetch(`/api/market/klines/day?${params}`, { cache: "no-store", signal: controller.signal })
      .then(async (response) => {
        if (!response.ok) {
          const payload = await response.json().catch(() => null) as { detail?: string } | null;
          if (response.status === 404) throw new Error("该交易对在所选日期没有可用的本地 5 分钟 K 线");
          throw new Error(payload?.detail ?? `HTTP ${response.status}`);
        }
        return response.json() as Promise<DailyKlineResult>;
      })
      .then(setData)
      .catch((reason: unknown) => {
        if (reason instanceof DOMException && reason.name === "AbortError") return;
        setError(reason instanceof Error ? reason.message : "无法读取K线数据");
      })
      .finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [entry.symbol, entry.utc_trade_date, intervalSeconds]);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const handleKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [onClose]);

  const points = data?.items ?? [];
  const first = points[0];
  const last = points[points.length - 1];
  const chartChange = first && last ? (last.close_price / first.open_price - 1) * 100 : null;
  return <div className="chart-modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="chart-modal" role="dialog" aria-modal="true" aria-labelledby="chart-modal-title">
      <header className="chart-modal-header">
        <div>
          <p className="eyebrow">本地时间 UTC+8 · {intervalSeconds / 60}分钟</p>
          <h2 id="chart-modal-title">{entry.symbol} <span>{formatKlineTradeWindow(entry.utc_trade_date)}</span></h2>
        </div>
        <div className="chart-modal-actions">
          <div className="chart-interval-switch" aria-label="K线周期">
            <button type="button" className={intervalSeconds === 300 ? "active" : ""} onClick={() => setIntervalSeconds(300)}>5min</button>
            <button type="button" className={intervalSeconds === 900 ? "active" : ""} onClick={() => setIntervalSeconds(900)}>15min</button>
          </div>
          {chartChange !== null && <strong className={changeClass(chartChange)}>{chartChange >= 0 ? "+" : ""}{chartChange.toFixed(4)}%</strong>}
          <button type="button" className="chart-close-button" onClick={onClose} aria-label="关闭K线图">×</button>
        </div>
      </header>
      {loading && <div className="chart-state">正在读取本地 K 线…</div>}
      {error && <div className="chart-state chart-state-error">K 线加载失败：{error}</div>}
      {data && data.items.length > 0 && <>
        <div className="chart-summary">
          <span>开盘 <strong>{formatNumber(first.open_price, 8)}</strong></span>
          <span>最高 <strong>{formatNumber(Math.max(...points.map((point) => point.high_price)), 8)}</strong></span>
          <span>最低 <strong>{formatNumber(Math.min(...points.map((point) => point.low_price)), 8)}</strong></span>
          <span>收盘 <strong>{formatNumber(last.close_price, 8)}</strong></span>
          <span>完整度 <strong>{points.length} / {intervalSeconds === 300 ? 287 : 96}</strong></span>
          <span className="ema20-label">━ EMA20</span>
          <span className="ema240-label">━ EMA240</span>
        </div>
        <CandlestickChart data={data} />
        <p className="chart-footnote">图表时间统一显示为 UTC+8；使用本地数据库中 VALID、已闭合的 Trade K 线。15min 由 5min 数据聚合，最后一根按排行榜次日 07:55（UTC+8）快照边界形成。EMA20/EMA240 使用前置数据预热；仅在本地存在有效观测时展示 OI。</p>
      </>}
    </section>
  </div>;
}

function RankingExplorer() {
  const [data, setData] = useState<RankingResult | null>(null);
  const [filters, setFilters] = useState<RankingFilters>({
    dateFrom: "",
    dateTo: "",
    symbol: "",
    rankFrom: 1,
    rankTo: 50
  });
  const [selected, setSelected] = useState<RankingEntry | null>(null);
  const [chartEntry, setChartEntry] = useState<RankingEntry | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  async function load(nextFilters: RankingFilters, page = 1) {
    setLoading(true);
    const params = new URLSearchParams({
      rank_from: String(nextFilters.rankFrom),
      rank_to: String(nextFilters.rankTo),
      page: String(page),
      page_size: "100"
    });
    if (nextFilters.dateFrom) params.set("date_from", nextFilters.dateFrom);
    if (nextFilters.dateTo) params.set("date_to", nextFilters.dateTo);
    if (nextFilters.symbol.trim()) params.set("symbol", nextFilters.symbol.trim());
    try {
      const response = await fetch(`/api/rankings/daily?${params}`, { cache: "no-store" });
      if (!response.ok) {
        const payload = await response.json().catch(() => null) as { detail?: string } | null;
        throw new Error(payload?.detail ?? `HTTP ${response.status}`);
      }
      const result = await response.json() as RankingResult;
      setData(result);
      setSelected((current) => result.items.find((item) =>
        current && item.utc_trade_date === current.utc_trade_date && item.rank_no === current.rank_no
      ) ?? result.items[0] ?? null);
      if (!nextFilters.dateFrom && !nextFilters.dateTo && result.date_from && result.date_to) {
        setFilters((current) => ({ ...current, dateFrom: result.date_from!, dateTo: result.date_to! }));
      }
      setError(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "无法读取涨幅榜");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { void load(filters); }, []);

  function applyRange(days: number | "all" | "latest") {
    if (!data?.available_first_date || !data.available_last_date) return;
    let from = data.available_last_date;
    if (days === "all") from = data.available_first_date;
    if (typeof days === "number") {
      const value = new Date(`${data.available_last_date}T00:00:00Z`);
      value.setUTCDate(value.getUTCDate() - days + 1);
      from = value.toISOString().slice(0, 10);
    }
    const next = { ...filters, dateFrom: from, dateTo: data.available_last_date };
    setFilters(next);
    void load(next);
  }

  function navigateDay(offset: -1 | 1) {
    const currentDay = selected?.utc_trade_date ?? data?.date_to;
    if (!currentDay || !data?.available_first_date || !data.available_last_date) return;
    const value = new Date(`${currentDay}T00:00:00Z`);
    value.setUTCDate(value.getUTCDate() + offset);
    const targetDay = value.toISOString().slice(0, 10);
    if (targetDay < data.available_first_date || targetDay > data.available_last_date) return;
    const next = { ...filters, dateFrom: targetDay, dateTo: targetDay };
    setFilters(next);
    void load(next);
  }

  const pages = data ? Math.max(1, Math.ceil(data.total / data.page_size)) : 1;
  const navigationDay = selected?.utc_trade_date ?? data?.date_to ?? null;
  const cannotGoPrevious = !data?.available_first_date || !navigationDay || navigationDay <= data.available_first_date;
  const cannotGoNext = !data?.available_last_date || !navigationDay || navigationDay >= data.available_last_date;

  function openChart(item: RankingEntry) {
    setSelected(item);
    setChartEntry(item);
  }

  return (
    <main>
      <header className="topbar ranking-header">
        <div>
          <p className="brand-mark">MARKET RESEARCH</p>
          <h1>UTC+8 日涨幅榜查询</h1>
          <p className="subtitle">UTC+8 08:00 开盘至次日 07:55 快照 · Binance USDⓈ-M 永续</p>
        </div>
        <div className="data-range-badge">
          <span>本地数据范围</span>
          <strong>{formatRankingDataRange(data?.available_first_date ?? null, data?.available_last_date ?? null)}</strong>
        </div>
      </header>

      {error && <div className="alert alert-critical">查询失败：{error}</div>}

      <section className="panel query-panel">
        <form onSubmit={(event) => { event.preventDefault(); void load(filters); }}>
          <label><span>开始交易日（UTC+8 08:00）</span><input type="date" value={filters.dateFrom} min={data?.available_first_date ?? undefined} max={data?.available_last_date ?? undefined} onChange={(event) => setFilters({ ...filters, dateFrom: event.target.value })} /></label>
          <label><span>结束交易日（UTC+8 08:00）</span><input type="date" value={filters.dateTo} min={data?.available_first_date ?? undefined} max={data?.available_last_date ?? undefined} onChange={(event) => setFilters({ ...filters, dateTo: event.target.value })} /></label>
          <label className="symbol-field"><span>交易对</span><input type="search" placeholder="例如 BTC 或 USDT" value={filters.symbol} onChange={(event) => setFilters({ ...filters, symbol: event.target.value.toUpperCase() })} /></label>
          <label><span>排名从</span><input type="number" min="1" max="50" value={filters.rankFrom} onChange={(event) => setFilters({ ...filters, rankFrom: Number(event.target.value) })} /></label>
          <label><span>排名至</span><input type="number" min="1" max="50" value={filters.rankTo} onChange={(event) => setFilters({ ...filters, rankTo: Number(event.target.value) })} /></label>
          <button className="primary-button" type="submit" disabled={loading}>{loading ? "查询中…" : "查询"}</button>
        </form>
        <div className="quick-ranges">
          <span>快捷范围</span>
          <button type="button" onClick={() => applyRange("latest")}>最新日</button>
          <button type="button" onClick={() => applyRange(7)}>近 7 日</button>
          <button type="button" onClick={() => applyRange(30)}>近 30 日</button>
          <button type="button" onClick={() => applyRange("all")}>全部 90 日</button>
        </div>
      </section>

      <section className="ranking-summary-grid">
        <article className="summary-card"><span>匹配记录</span><strong>{data?.total.toLocaleString() ?? "—"}</strong><small>{data?.matching_days ?? 0} 个 UTC+8 交易区间</small></article>
        <article className="summary-card"><span>区间最高涨幅</span><strong className="change-positive">{data?.maximum_change == null ? "—" : `+${data.maximum_change.toFixed(2)}%`}</strong><small>筛选结果中的最大值</small></article>
        <article className="summary-card"><span>平均涨幅</span><strong className={changeClass(data?.average_change ?? 0)}>{data?.average_change == null ? "—" : `${data.average_change.toFixed(2)}%`}</strong><small>当前筛选口径</small></article>
        <article className="summary-card"><span>区间最低涨幅</span><strong className={changeClass(data?.minimum_change ?? 0)}>{data?.minimum_change == null ? "—" : `${data.minimum_change.toFixed(2)}%`}</strong><small>Top 50 尾部可能为负</small></article>
      </section>

      <section className="ranking-workspace">
        <article className="panel ranking-table-panel">
          <div className="panel-heading ranking-table-heading">
            <div><p className="eyebrow">查询结果</p><h3>每日排名明细</h3></div>
            <span className="message">第 {data?.page ?? 1} / {pages} 页</span>
          </div>
          <div className="table-scroll ranking-scroll">
            <table className="storage-table ranking-table">
              <thead><tr><th>UTC+8 时间区间</th><th>排名</th><th>交易对</th><th>涨幅</th><th>开盘价</th><th>快照价</th><th>振幅</th><th>成交额</th><th>OI</th></tr></thead>
              <tbody>
                {data?.items.map((item) => (
                  <tr key={`${item.utc_trade_date}-${item.rank_no}`} className={selected?.utc_trade_date === item.utc_trade_date && selected.rank_no === item.rank_no ? "selected-row" : ""} role="button" tabIndex={0} aria-label={`查看 ${item.symbol} ${formatKlineTradeWindow(item.utc_trade_date)} K线`} onClick={() => openChart(item)} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); openChart(item); } }}>
                    <td>{formatKlineTradeWindow(item.utc_trade_date)}</td><td><span className={`rank-badge rank-${Math.min(item.rank_no, 4)}`}>{item.rank_no}</span></td><td><a className="symbol-link" href={`https://www.binance.com/zh-CN/futures/${encodeURIComponent(item.symbol)}`} target="_blank" rel="noopener noreferrer" title={`在 Binance Futures 查看 ${item.symbol}`} onClick={(event) => event.stopPropagation()} onKeyDown={(event) => event.stopPropagation()}><strong>{item.symbol}</strong><span aria-hidden="true">↗</span></a></td>
                    <td className={changeClass(item.price_change)}>{item.price_change >= 0 ? "+" : ""}{item.price_change.toFixed(4)}%</td>
                    <td>{formatNumber(item.reference_open_price, 8)}</td><td>{formatNumber(item.snapshot_price, 8)}</td><td>{formatNumber(item.amplitude, 2)}%</td><td>{formatCompact(item.quote_volume)}</td><td>{item.open_interest_status === "LOCAL_OBSERVATION" ? "有" : "—"}</td>
                  </tr>
                ))}
                {!loading && data?.items.length === 0 && <tr><td className="empty-cell" colSpan={9}>没有符合条件的数据</td></tr>}
              </tbody>
            </table>
          </div>
          <div className="pagination">
            <button disabled={loading || cannotGoPrevious} onClick={() => navigateDay(-1)}>上一日</button>
            <span>{data?.total.toLocaleString() ?? 0} 条 · 每页 {data?.page_size ?? 100} 条</span>
            <button disabled={loading || cannotGoNext} onClick={() => navigateDay(1)}>下一日</button>
          </div>
        </article>

        <aside className="panel ranking-detail">
          <p className="eyebrow">记录详情</p>
          {selected ? <>
            <div className="detail-hero"><div><span>#{selected.rank_no}</span><h2>{selected.symbol}</h2><small>{formatKlineTime(selected.snapshot_at)}</small></div><strong className={changeClass(selected.price_change)}>{selected.price_change >= 0 ? "+" : ""}{selected.price_change.toFixed(4)}%</strong></div>
            <dl className="metric-list">
              <div><dt>08:00 开盘价</dt><dd>{formatNumber(selected.reference_open_price, 10)}</dd></div>
              <div><dt>次日 07:55 快照价</dt><dd>{formatNumber(selected.snapshot_price, 10)}</dd></div>
              <div><dt>日内最高</dt><dd>{formatNumber(selected.period_high_price, 10)}</dd></div>
              <div><dt>日内最低</dt><dd>{formatNumber(selected.period_low_price, 10)}</dd></div>
              <div><dt>日内振幅</dt><dd>{formatNumber(selected.amplitude, 4)}%</dd></div>
              <div><dt>Quote 成交额</dt><dd>{formatNumber(selected.quote_volume, 2)}</dd></div>
              <div><dt>Base 成交量</dt><dd>{formatNumber(selected.base_volume, 2)}</dd></div>
              <div><dt>Open Interest</dt><dd>{formatNumber(selected.open_interest_qty, 4)}</dd></div>
              <div><dt>OI 价值</dt><dd>{formatNumber(selected.open_interest_value, 2)}</dd></div>
              <div><dt>OI 状态</dt><dd>{selected.open_interest_status === "LOCAL_OBSERVATION" ? "本地观测" : "历史不可用"}</dd></div>
            </dl>
            <p className="detail-note">快照时间 {formatKlineTime(selected.snapshot_at)}。榜单为 5 分钟 K 线重建结果，不冒充当时实时采集快照。</p>
          </> : <p className="message">选择一条记录查看完整指标。</p>}
        </aside>
      </section>
      {chartEntry && <KlineModal entry={chartEntry} onClose={() => setChartEntry(null)} />}
    </main>
  );
}

function MonitoringDashboard() {
  const [data, setData] = useState<MonitoringSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const refreshInFlight = useRef(false);

  async function refresh() {
    if (refreshInFlight.current) return;
    refreshInFlight.current = true;
    try {
      const response = await fetch("/api/monitoring/overview", { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      setData((await response.json()) as MonitoringSnapshot);
      setError(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "无法连接监控服务");
    } finally {
      refreshInFlight.current = false;
      setLoading(false);
    }
  }

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 15_000);
    return () => window.clearInterval(timer);
  }, []);

  return (
    <main>
      <header className="topbar">
        <div>
          <p className="brand-mark">AUTO TRADE 2.0</p>
          <h1>采集系统监控台</h1>
          <p className="subtitle">Binance USDⓈ-M · UTC数据链路 · 15秒自动刷新</p>
        </div>
        <div className="header-actions">
          {data && <StatusPill status={data.overall_status} />}
          <button onClick={() => void refresh()} disabled={loading}>立即刷新</button>
        </div>
      </header>

      {error && <div className="alert alert-critical">监控API不可用：{error}</div>}
      {loading && !data && <div className="loading">正在读取采集状态…</div>}

      {data && (
        <>
          <section className="summary-grid">
            <article className="hero-card">
              <p className="eyebrow">总体状态</p>
              <div className="hero-status"><StatusPill status={data.overall_status} /></div>
              <p>{data.environment} · {data.node_id}</p>
              <small>生成于 {formatUtc(data.generated_at)}</small>
            </article>
            <article className="summary-card">
              <span>正常交易标的</span><strong>{data.active_symbols}</strong><small>USDT永续</small>
            </article>
            <article className="summary-card">
              <span>数据库空间</span><strong>{data.database.size_display}</strong><small>{data.database.message}</small>
            </article>
            <article className="summary-card">
              <span>REST权重 · 近10分钟峰值</span>
              <strong>{data.rest_usage.used_weight_1m ?? "—"}<em> / {data.rest_usage.limit_1m}</em></strong>
              <small>
                近1小时加权均值 {data.rest_usage.average_used_weight_1h == null
                  ? "—"
                  : Math.round(data.rest_usage.average_used_weight_1h)} / {data.rest_usage.limit_1m}
                {data.rest_usage.average_utilization_percent_1h == null
                  ? ""
                  : ` · ${data.rest_usage.average_utilization_percent_1h}%`}
                {data.rest_usage.sampled_minutes_1h > 0
                  ? ` · ${data.rest_usage.sampled_minutes_1h}分钟样本`
                  : ""}
              </small>
              <small>峰值 {data.rest_usage.utilization_percent ?? 0}% · {data.rest_usage.message}</small>
            </article>
          </section>

          {data.notices.map((notice) => <div className="alert" key={notice}>{notice}</div>)}

          <section>
            <div className="section-title"><p className="eyebrow">核心链路</p><h2>实时数据完整性</h2></div>
            <div className="coverage-grid">
              {data.coverage.map((metric) => <CoverageCard key={metric.key} metric={metric} />)}
            </div>
          </section>

          <section>
            <div className="section-title"><p className="eyebrow">WebSocket链路</p><h2>近1小时同步成功率</h2></div>
            <div className="coverage-grid">
              {data.websocket_sync.map((metric) => (
                <article className="panel coverage-card" key={metric.key}>
                  <div className="panel-heading"><h3>{metric.label}</h3><StatusPill status={metric.status} /></div>
                  <div className="coverage-number"><strong>{metric.success_percent.toFixed(2)}%</strong></div>
                  <div className="progress"><span style={{ width: `${Math.min(100, metric.success_percent)}%` }} /></div>
                  <dl className="detail-grid">
                    <div><dt>成功</dt><dd>{metric.succeeded}</dd></div>
                    <div><dt>失败</dt><dd>{metric.failed}</dd></div>
                    <div><dt>REST兜底</dt><dd>{metric.rest_fallback}</dd></div>
                    <div><dt>仍缺失</dt><dd>{metric.missing}</dd></div>
                  </dl>
                  <p className="message">期望 {metric.expected} 根已闭合K线；其他来源 {metric.other_source}。</p>
                </article>
              ))}
            </div>
          </section>

          <section className="operations-grid">
            <article className="panel">
              <div className="panel-heading"><div><p className="eyebrow">修复系统</p><h3>回补队列</h3></div><StatusPill status={data.backfill.status} /></div>
              <div className="queue-grid">
                <div><span>当前等待</span><strong>{data.backfill.counts.pending}</strong></div>
                <div><span>当前运行</span><strong>{data.backfill.counts.running}</strong></div>
                <div><span>历史成功</span><strong>{data.backfill.counts.succeeded}</strong></div>
                <div><span>历史失败</span><strong>{data.backfill.counts.failed}</strong></div>
              </div>
              <div className="backfill-scope">
                <div className="backfill-scope-row">
                  <span>当前回补数据</span>
                  {data.backfill.running_jobs.length > 0 ? data.backfill.running_jobs.map((job) => (
                    <div className="backfill-job" key={`${job.symbol}-${job.range_start}`}>
                      <strong>{job.symbol}</strong>
                      <small>{formatBackfillSeries(job.data_type, job.interval_seconds)}</small>
                      <time>{formatUtcRange(job.range_start, job.range_end)}</time>
                    </div>
                  )) : <p>当前无运行任务，等待下一轮领取</p>}
                </div>
                <div className="backfill-scope-row">
                  <span>等待队列数据范围</span>
                  <time>{formatUtcRange(data.backfill.pending_range_start, data.backfill.pending_range_end)}</time>
                  <small>{data.backfill.counts.pending} 个待处理任务</small>
                </div>
              </div>
              <dl className="repair-details">
                <div><dt>近1小时成功</dt><dd>{data.backfill.succeeded_last_hour} 个</dd></div>
                <div><dt>近1小时新增</dt><dd>{data.backfill.created_last_hour} 个</dd></div>
                <div><dt>新增−结束（1h）</dt><dd className={data.backfill.queue_delta_last_hour > 0 ? "trend-up" : "trend-down"}>{formatDelta(data.backfill.queue_delta_last_hour)}</dd></div>
                <div>
                  <dt>预计清空</dt>
                  <dd>
                    {data.backfill.queue_delta_last_hour > 0
                      ? "无法清空（仍增长）"
                      : formatAge(data.backfill.estimated_clear_seconds)}
                  </dd>
                </div>
                <div><dt>最近成功</dt><dd>{formatUtc(data.backfill.last_succeeded_at)}</dd></div>
                <div><dt>最老等待</dt><dd>{formatAge(data.backfill.oldest_pending_seconds)}</dd></div>
              </dl>
              <p className="message">开放缺口 {data.backfill.open_gaps} · {data.backfill.message}</p>
              <p className="queue-explanation">“当前等待”是动态队列存量；缺口扫描新增量与完成量接近时，数量可能基本不变。</p>
            </article>

            <article className="panel">
              <div className="panel-heading"><div><p className="eyebrow">事件总线</p><h3>NATS JetStream</h3></div><StatusPill status={data.nats.status} /></div>
              <div className="stream-list">
                {data.nats.streams.map((stream) => (
                  <div key={stream.name}><span>{stream.name}</span><strong>{stream.messages.toLocaleString()}</strong><small>{stream.consumers} consumers</small></div>
                ))}
              </div>
              <p className="message">{data.nats.message}</p>
            </article>
          </section>

          <section className="database-section">
            <article className="panel">
              <div className="panel-heading">
                <div><p className="eyebrow">存储与查询效率</p><h3>数据库容量明细</h3></div>
                <StatusPill status={data.database.status} />
              </div>
              <div className="database-summary">
                <div><span>数据库总容量</span><strong>{data.database.size_display}</strong></div>
                <div><span>缓存命中率</span><strong>{data.database.cache_hit_percent === null ? "—" : `${data.database.cache_hit_percent.toFixed(2)}%`}</strong></div>
                <div><span>展示关系</span><strong>Top {data.database.largest_tables.length}</strong></div>
              </div>
              <div className="table-scroll">
                <table className="storage-table">
                  <thead><tr><th>表</th><th>类型</th><th>分块</th><th>Columnstore</th><th>节省</th><th>估算行数</th><th>数据</th><th>索引</th><th>辅助/TOAST</th><th>合计</th></tr></thead>
                  <tbody>
                    {data.database.largest_tables.map((table) => (
                      <tr key={`${table.schema_name}.${table.table_name}`}>
                        <td><strong>{table.schema_name}.{table.table_name}</strong></td>
                        <td>{table.is_hypertable ? "Hypertable" : "Table"}</td>
                        <td>{table.chunk_count ?? "—"}</td>
                        <td>{table.compression_enabled === null ? "—" : !table.compression_enabled ? "未配置" : table.columnstore_chunks > 0 ? `${table.columnstore_chunks}/${table.chunk_count ?? "—"} 分块` : table.columnstore_policy_enabled ? "等待72h冷却" : "已配置/无策略"}</td>
                        <td>{table.columnstore_saved_percent === null ? "—" : `${table.columnstore_saved_percent.toFixed(1)}%`}</td>
                        <td>{table.estimated_rows.toLocaleString()}</td>
                        <td>{formatBytes(table.table_bytes)}</td>
                        <td>{formatBytes(table.index_bytes)}</td>
                        <td>{formatBytes(table.toast_bytes)}</td>
                        <td><strong>{formatBytes(table.total_bytes)}</strong></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <p className="message">行数为PostgreSQL统计估算值；Columnstore只转换超过72小时的完整分块，不会触碰实时写入和24小时回补窗口。</p>
            </article>
          </section>
        </>
      )}
    </main>
  );
}

function App() {
  const [view, setView] = useState<"rankings" | "monitoring">("rankings");
  return <>
    <nav className="workspace-tabs" aria-label="工具导航">
      <button className={view === "rankings" ? "active" : ""} onClick={() => setView("rankings")}>数据查询</button>
      <button className={view === "monitoring" ? "active" : ""} onClick={() => setView("monitoring")}>采集监控</button>
    </nav>
    {view === "rankings" ? <RankingExplorer /> : <MonitoringDashboard />}
  </>;
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode><App /></React.StrictMode>
);
