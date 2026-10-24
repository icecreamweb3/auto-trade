import React, { useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  CandlestickSeries,
  ColorType,
  createChart,
  HistogramSeries,
  LineSeries,
  LineStyle,
  type IChartApi,
  type IPriceLine,
  type ISeriesApi,
  type LogicalRange,
  type MouseEventParams,
  type Time,
  type UTCTimestamp,
} from "lightweight-charts";
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
  price_change_percent: number;
  amplitude_percent: number;
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

interface LoadedKlineRange {
  firstOpenTime: string;
  lastCloseTime: string;
  count: number;
}

type PaperSide = "LONG" | "SHORT";
type PaperNotionalUnit = "USDT" | "BASE";
type PaperGameStatus = "READY" | "RUNNING" | "COMPLETED" | "LIQUIDATED";
type PaperReplaySource = "CUSTOM" | "US" | "ASIA";

interface PaperCandle {
  open_time: string;
  close_time: string;
  open_price: number;
  high_price: number;
  low_price: number;
  close_price: number;
  base_volume: number;
  quote_volume: number;
}

type PaperCandleReadout = Pick<
  PaperCandle,
  "open_time" | "open_price" | "high_price" | "low_price" | "close_price"
> & { ema20: number | null; ema240: number | null };

interface PaperPosition {
  side: PaperSide;
  leverage: number;
  margin: number;
  quantity: number;
  entry_price: number;
  mark_price: number;
  liquidation_price: number;
  take_profit_price: number | null;
  take_profit_quantity: number | null;
  stop_loss_price: number | null;
  unrealized_pnl: number;
  return_on_margin_percent: number;
}

interface PaperTrade {
  side: PaperSide;
  leverage: number;
  margin: number;
  quantity: number;
  entry_price: number;
  exit_price: number;
  realized_pnl: number;
  opened_at: string;
  closed_at: string;
  exit_reason: string;
}

interface PaperPendingOrder {
  order_id: string;
  order_kind: "OPEN" | "CLOSE";
  order_type: "LIMIT" | "STOP_MARKET";
  position_side: PaperSide;
  price: number;
  quantity: number;
  leverage: number;
  created_at: string;
}

interface PaperSessionSnapshot {
  session_id: string;
  symbol: string;
  interval_seconds: number;
  range_start: string;
  range_end: string;
  status: PaperGameStatus;
  starting_balance: number;
  balance: number;
  available_balance: number;
  equity: number;
  realized_pnl: number;
  revealed_count: number;
  total_candles: number;
  current_candle: PaperCandle;
  ema20: number | null;
  ema240: number | null;
  anchored_price_change: number | null;
  anchored_price_change_percent: number | null;
  position: PaperPosition | null;
  pending_orders: PaperPendingOrder[];
  trades: PaperTrade[];
  message: string | null;
}

interface PaperChartPoint extends PaperCandle {
  ema20: number | null;
  ema240: number | null;
}

interface PaperTimeAxisLabel {
  key: string;
  left: number;
  text: string;
}

interface PaperOrderControl {
  orderId: string;
  top: number;
  right: number;
  label: string;
  kind: "take-profit" | "stop-loss";
}

interface PaperOpeningRange {
  high: number;
  low: number;
  sessionStartMs: number;
  sessionEndMs: number;
  completed: boolean;
}

interface PaperOpeningRangeOverlay {
  width: number;
  height: number;
  rangeLeft: number;
  rangeRight: number;
  projectionRight: number;
  highY: number;
  lowY: number;
  upperOneY: number;
  upperTwoY: number;
  lowerOneY: number;
  lowerTwoY: number;
  high: number;
  low: number;
  trueRange: number;
  completed: boolean;
}

interface PaperMetadata {
  symbols: string[];
  intervals: number[];
  starting_balance: number;
  maximum_leverage: number;
  maintenance_margin_rate: number;
  ranges: Array<{ symbol: string; available_from: string | null; available_to: string | null }>;
}

interface PaperReplayPreset {
  id: string;
  symbol: string;
  intervalSeconds: number;
  rangeStart: string;
  rangeEnd: string;
}

interface PaperTraderPreferences {
  symbol: string;
  interval_seconds: number;
  range_start: string | null;
  range_end: string | null;
  speed_seconds: number;
  notional: number;
  notional_unit: PaperNotionalUnit;
  leverage: number;
  open_order_type: "LIMIT" | "MARKET";
  close_order_type: "LIMIT" | "MARKET";
  auto_two_r_take_profit: boolean;
  show_opening_range: boolean;
  show_upper_opening_range: boolean;
  show_lower_opening_range: boolean;
  replay_presets: Array<{
    id: string;
    symbol: string;
    interval_seconds: number;
    range_start: string;
    range_end: string;
  }>;
}

interface AccountSummary {
  starting_balance: number;
  balance: number;
  realized_pnl: number;
  trade_count: number;
}

interface CurrentUser {
  user_id: string;
  email: string;
  username: string | null;
  role: "NORMAL" | "ADVANCED" | "ADMIN";
  created_at: string;
  account: AccountSummary;
}

interface AdminUser {
  user_id: string;
  email: string;
  username: string | null;
  role: "NORMAL" | "ADVANCED" | "ADMIN";
  created_at: string;
  balance: number;
  trade_count: number;
}

interface AccountTrade extends PaperTrade {
  trade_id: string;
  session_id: string;
  symbol: string;
  interval_seconds: number;
  balance_before: number;
  balance_after: number;
}

interface AccountTradeHistory {
  account: AccountSummary;
  trades: AccountTrade[];
}

type NumericInput = number | "";

interface RankingFilters {
  dateFrom: string;
  dateTo: string;
  symbol: string;
  rankFrom: NumericInput;
  rankTo: NumericInput;
}

type FactorName = "bullish_candle_sequence" | "single_bar_price_rise" | "volume_acceleration" | "ema_bullish_setup" | "ema_bullish_cross" | "rapid_price_rise" | "open_interest_rise" | "volume_surge" | "amplitude_spike_streak" | "low_average_amplitude";
type BacktestStatus = "QUEUED" | "RUNNING" | "COMPLETED" | "FAILED";
type BacktestInterval = 300 | 900;

interface BacktestIntervalMetadata {
  available_from: string | null;
  available_to: string | null;
  symbols: string[];
}

interface BacktestMetadata {
  intervals: Record<"300" | "900", BacktestIntervalMetadata>;
}

interface BacktestFactorResult {
  passed: boolean;
  value: number | null;
  threshold: string;
  reason: string | null;
}

interface BacktestSignal {
  symbol: string;
  open_time: string;
  close_price: number;
  factors: Record<FactorName, BacktestFactorResult>;
}

interface BacktestJob {
  job_id: string;
  status: BacktestStatus;
  scanned_instruments: number;
  total_instruments: number;
  signal_count: number;
  truncated: boolean;
  max_signals: number;
  log_line_count: number;
  log_truncated: boolean;
  log_available: boolean;
  log_url: string | null;
  max_log_lines: number;
  error: string | null;
  request: { interval_seconds: BacktestInterval; generate_log: boolean; preserve_log_history: boolean; parameters: { required_factors: FactorName[] } };
  signals: BacktestSignal[];
}

interface BacktestKlineResult {
  symbol: string;
  signal_time: string;
  interval_seconds: number;
  items: KlinePoint[];
}

interface BacktestParameterPayload {
  average_days: number;
  bullish_sequence_bars: number;
  bullish_min_close_position_percent: number;
  bullish_last_close_position_percent: number;
  bullish_last_max_upper_shadow_percent: number;
  single_bar_price_rise_percent: number;
  volume_acceleration_average_bars: number;
  volume_acceleration_average_multiple: number;
  volume_acceleration_previous_multiple: number;
  ema_near_cross_gap_percent: number;
  ema_gap_shrink_min_percent: number;
  ema_cross_lookback_bars: number;
  rapid_price_window_bars: number;
  rapid_price_rise_percent: number;
  open_interest_window_bars: number;
  open_interest_rise_percent: number;
  volume_surge_multiple: number;
  amplitude_spike_multiple: number;
  amplitude_consecutive_bars: number;
  average_amplitude_max_percent: number;
  required_factors: FactorName[];
}

interface SavedBacktestStrategy {
  strategy_id: string;
  name: string;
  description: string;
  interval_seconds: BacktestInterval;
  parameters: BacktestParameterPayload;
  created_at: string;
  updated_at: string;
}

interface BacktestParameterValues {
  averageDays: NumericInput;
  bullishSequenceBars: NumericInput;
  bullishMinClosePositionPercent: NumericInput;
  bullishLastClosePositionPercent: NumericInput;
  bullishLastMaxUpperShadowPercent: NumericInput;
  singleBarPriceRisePercent: NumericInput;
  volumeAccelerationAverageBars: NumericInput;
  volumeAccelerationAverageMultiple: NumericInput;
  volumeAccelerationPreviousMultiple: NumericInput;
  emaNearCrossGapPercent: NumericInput;
  emaGapShrinkMinPercent: NumericInput;
  emaCrossBars: NumericInput;
  priceWindowBars: NumericInput;
  priceRisePercent: NumericInput;
  oiWindowBars: NumericInput;
  oiRisePercent: NumericInput;
  volumeMultiple: NumericInput;
  amplitudeMultiple: NumericInput;
  amplitudeConsecutiveBars: NumericInput;
  averageAmplitudeMaxPercent: NumericInput;
}

const defaultBacktestParameters: Record<keyof BacktestParameterValues, number> = {
  averageDays: 7,
  bullishSequenceBars: 2,
  bullishMinClosePositionPercent: 50,
  bullishLastClosePositionPercent: 85,
  bullishLastMaxUpperShadowPercent: 15,
  singleBarPriceRisePercent: 3,
  volumeAccelerationAverageBars: 20,
  volumeAccelerationAverageMultiple: 2,
  volumeAccelerationPreviousMultiple: 1.3,
  emaNearCrossGapPercent: 1,
  emaGapShrinkMinPercent: 30,
  emaCrossBars: 4,
  priceWindowBars: 4,
  priceRisePercent: 3,
  oiWindowBars: 4,
  oiRisePercent: 5,
  volumeMultiple: 5,
  amplitudeMultiple: 5,
  amplitudeConsecutiveBars: 2,
  averageAmplitudeMaxPercent: 2
};

const backtestParameterLabels: Record<keyof BacktestParameterValues, string> = {
  averageDays: "均值周期",
  bullishSequenceBars: "连续阳线数量",
  bullishMinClosePositionPercent: "前序阳线最低收盘位置",
  bullishLastClosePositionPercent: "最后阳线最低收盘位置",
  bullishLastMaxUpperShadowPercent: "最后阳线最大上影线",
  singleBarPriceRisePercent: "单根 K 线涨幅",
  volumeAccelerationAverageBars: "成交量均值窗口",
  volumeAccelerationAverageMultiple: "成交量均值倍数",
  volumeAccelerationPreviousMultiple: "上一根成交量倍数",
  emaNearCrossGapPercent: "EMA 最大临近差距",
  emaGapShrinkMinPercent: "EMA 差距最小收缩幅度",
  emaCrossBars: "EMA 上穿窗口",
  priceWindowBars: "价格窗口",
  priceRisePercent: "价格涨幅",
  oiWindowBars: "OI 窗口",
  oiRisePercent: "OI 涨幅",
  volumeMultiple: "成交量倍数",
  amplitudeMultiple: "振幅倍数",
  amplitudeConsecutiveBars: "连续 K 线数量",
  averageAmplitudeMaxPercent: "平均振幅上限"
};

function requiredBacktestParameterKeys(selectedFactors: FactorName[]): Set<keyof BacktestParameterValues> {
  const keys = new Set<keyof BacktestParameterValues>();
  if (selectedFactors.includes("bullish_candle_sequence")) {
    keys.add("bullishSequenceBars");
    keys.add("bullishMinClosePositionPercent");
    keys.add("bullishLastClosePositionPercent");
    keys.add("bullishLastMaxUpperShadowPercent");
  }
  if (selectedFactors.includes("single_bar_price_rise")) keys.add("singleBarPriceRisePercent");
  if (selectedFactors.includes("volume_acceleration")) {
    keys.add("volumeAccelerationAverageBars");
    keys.add("volumeAccelerationAverageMultiple");
    keys.add("volumeAccelerationPreviousMultiple");
  }
  if (selectedFactors.includes("ema_bullish_setup")) {
    keys.add("emaNearCrossGapPercent");
    keys.add("emaGapShrinkMinPercent");
  }
  if (selectedFactors.includes("ema_bullish_cross")) keys.add("emaCrossBars");
  if (selectedFactors.includes("rapid_price_rise")) {
    keys.add("priceWindowBars");
    keys.add("priceRisePercent");
  }
  if (selectedFactors.includes("open_interest_rise")) {
    keys.add("oiWindowBars");
    keys.add("oiRisePercent");
  }
  if (selectedFactors.includes("volume_surge")) keys.add("volumeMultiple");
  if (selectedFactors.includes("amplitude_spike_streak")) {
    keys.add("amplitudeMultiple");
    keys.add("amplitudeConsecutiveBars");
  }
  if (selectedFactors.includes("low_average_amplitude")) keys.add("averageAmplitudeMaxPercent");
  if (selectedFactors.some((name) => name === "volume_surge" || name === "amplitude_spike_streak" || name === "low_average_amplitude")) keys.add("averageDays");
  return keys;
}

function buildBacktestParameterPayload(parameters: BacktestParameterValues, selectedFactors: FactorName[]): BacktestParameterPayload {
  const value = (key: keyof BacktestParameterValues): number => parameters[key] === "" ? defaultBacktestParameters[key] : parameters[key];
  return {
    average_days: value("averageDays"),
    bullish_sequence_bars: value("bullishSequenceBars"),
    bullish_min_close_position_percent: value("bullishMinClosePositionPercent"),
    bullish_last_close_position_percent: value("bullishLastClosePositionPercent"),
    bullish_last_max_upper_shadow_percent: value("bullishLastMaxUpperShadowPercent"),
    single_bar_price_rise_percent: value("singleBarPriceRisePercent"),
    volume_acceleration_average_bars: value("volumeAccelerationAverageBars"),
    volume_acceleration_average_multiple: value("volumeAccelerationAverageMultiple"),
    volume_acceleration_previous_multiple: value("volumeAccelerationPreviousMultiple"),
    ema_near_cross_gap_percent: value("emaNearCrossGapPercent"),
    ema_gap_shrink_min_percent: value("emaGapShrinkMinPercent"),
    ema_cross_lookback_bars: value("emaCrossBars"),
    rapid_price_window_bars: value("priceWindowBars"),
    rapid_price_rise_percent: value("priceRisePercent"),
    open_interest_window_bars: value("oiWindowBars"),
    open_interest_rise_percent: value("oiRisePercent"),
    volume_surge_multiple: value("volumeMultiple"),
    amplitude_spike_multiple: value("amplitudeMultiple"),
    amplitude_consecutive_bars: value("amplitudeConsecutiveBars"),
    average_amplitude_max_percent: value("averageAmplitudeMaxPercent"),
    required_factors: selectedFactors
  };
}

function parameterValuesFromPayload(value: BacktestParameterPayload): BacktestParameterValues {
  return {
    averageDays: Number(value.average_days),
    bullishSequenceBars: Number(value.bullish_sequence_bars),
    bullishMinClosePositionPercent: Number(value.bullish_min_close_position_percent),
    bullishLastClosePositionPercent: Number(value.bullish_last_close_position_percent),
    bullishLastMaxUpperShadowPercent: Number(value.bullish_last_max_upper_shadow_percent),
    singleBarPriceRisePercent: Number(value.single_bar_price_rise_percent),
    volumeAccelerationAverageBars: Number(value.volume_acceleration_average_bars),
    volumeAccelerationAverageMultiple: Number(value.volume_acceleration_average_multiple),
    volumeAccelerationPreviousMultiple: Number(value.volume_acceleration_previous_multiple),
    emaNearCrossGapPercent: Number(value.ema_near_cross_gap_percent),
    emaGapShrinkMinPercent: Number(value.ema_gap_shrink_min_percent),
    emaCrossBars: Number(value.ema_cross_lookback_bars),
    priceWindowBars: Number(value.rapid_price_window_bars),
    priceRisePercent: Number(value.rapid_price_rise_percent),
    oiWindowBars: Number(value.open_interest_window_bars),
    oiRisePercent: Number(value.open_interest_rise_percent),
    volumeMultiple: Number(value.volume_surge_multiple),
    amplitudeMultiple: Number(value.amplitude_spike_multiple),
    amplitudeConsecutiveBars: Number(value.amplitude_consecutive_bars),
    averageAmplitudeMaxPercent: Number(value.average_amplitude_max_percent)
  };
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

function formatPaperAxisTime(value: string): string {
  return utc8Iso(value).slice(11, 16);
}

function calculatePaperOpeningRange(candles: PaperChartPoint[]): PaperOpeningRange | null {
  const latest = candles[candles.length - 1];
  if (!latest) return null;
  const latestUtcMs = new Date(latest.open_time).getTime();
  if (!Number.isFinite(latestUtcMs)) return null;

  const latestLocal = new Date(latestUtcMs + UTC8_OFFSET_MS);
  const localMidnightMs = Date.UTC(
    latestLocal.getUTCFullYear(),
    latestLocal.getUTCMonth(),
    latestLocal.getUTCDate()
  );
  const latestLocalMinutes = latestLocal.getUTCHours() * 60 + latestLocal.getUTCMinutes();
  const sessionStartLocalMs = localMidnightMs
    + (latestLocalMinutes >= 21 * 60 + 30 ? 21 * 60 + 30 : -(24 * 60 - 21 * 60 - 30)) * 60 * 1000;
  const sessionStartUtcMs = sessionStartLocalMs - UTC8_OFFSET_MS;
  const sessionEndUtcMs = sessionStartUtcMs + 90 * 60 * 1000;
  const rangeCandles = candles.filter((candle) => {
    const openTimeMs = new Date(candle.open_time).getTime();
    return openTimeMs >= sessionStartUtcMs && openTimeMs < sessionEndUtcMs;
  });
  if (rangeCandles.length === 0) return null;
  return {
    high: Math.max(...rangeCandles.map((candle) => candle.high_price)),
    low: Math.min(...rangeCandles.map((candle) => candle.low_price)),
    sessionStartMs: sessionStartUtcMs,
    sessionEndMs: sessionEndUtcMs,
    completed: latestUtcMs >= sessionEndUtcMs,
  };
}

function formatKlineTradeWindow(utcTradeDate: string): string {
  const start = utc8Iso(`${utcTradeDate}T00:00:00Z`);
  const end = utc8Iso(`${utcTradeDate}T23:55:00Z`);
  return `${start.slice(0, 10)} ${start.slice(11, 16)} – ${end.slice(0, 10)} ${end.slice(11, 16)}`;
}

function formatLoadedKlineWindow(points: KlinePoint[], utcTradeDate: string): string {
  if (points.length === 0) return formatKlineTradeWindow(utcTradeDate);
  return formatKlineWindow(points[0].open_time, points[points.length - 1].close_time);
}

function formatKlineWindow(firstOpenTime: string, lastCloseTime: string): string {
  const start = utc8Iso(firstOpenTime);
  const end = utc8Iso(lastCloseTime);
  return `${start.slice(0, 10)} ${start.slice(11, 16)} – ${end.slice(0, 10)} ${end.slice(11, 16)}`;
}

function toUtc8Input(value: string): string {
  return utc8Iso(value).slice(0, 16);
}

function utc8InputToIso(value: string): string {
  return new Date(`${value}:00+08:00`).toISOString();
}

function randomTradingSession(
  availableFrom: string,
  availableTo: string,
  startHour: number,
  startMinute: number,
  durationHours: number,
  weekdaysOnly: boolean,
  randomValue = Math.random()
): { rangeStart: string; rangeEnd: string } | null {
  const availableFromMs = new Date(availableFrom).getTime();
  const availableToMs = new Date(availableTo).getTime();
  if (!Number.isFinite(availableFromMs) || !Number.isFinite(availableToMs)) return null;

  const firstLocalDate = new Date(availableFromMs + UTC8_OFFSET_MS);
  const lastLocalDate = new Date(availableToMs + UTC8_OFFSET_MS);
  let localMidnightMs = Date.UTC(
    firstLocalDate.getUTCFullYear(),
    firstLocalDate.getUTCMonth(),
    firstLocalDate.getUTCDate()
  );
  const lastLocalMidnightMs = Date.UTC(
    lastLocalDate.getUTCFullYear(),
    lastLocalDate.getUTCMonth(),
    lastLocalDate.getUTCDate()
  );
  const candidates: number[] = [];
  while (localMidnightMs <= lastLocalMidnightMs) {
    const weekday = new Date(localMidnightMs).getUTCDay();
    const sessionStartMs = localMidnightMs + (startHour * 60 + startMinute) * 60 * 1000 - UTC8_OFFSET_MS;
    const sessionEndMs = sessionStartMs + durationHours * 60 * 60 * 1000;
    if (
      (!weekdaysOnly || (weekday >= 1 && weekday <= 5)) &&
      sessionStartMs >= availableFromMs &&
      sessionEndMs <= availableToMs
    ) {
      candidates.push(sessionStartMs);
    }
    localMidnightMs += 24 * 60 * 60 * 1000;
  }
  if (candidates.length === 0) return null;

  const boundedRandom = Math.min(Math.max(randomValue, 0), 0.9999999999999999);
  const sessionStartMs = candidates[Math.floor(boundedRandom * candidates.length)];
  return {
    rangeStart: toUtc8Input(new Date(sessionStartMs).toISOString()),
    rangeEnd: toUtc8Input(new Date(sessionStartMs + durationHours * 60 * 60 * 1000).toISOString())
  };
}

function paperReplayPresetLabel(preset: PaperReplayPreset): string {
  const interval = preset.intervalSeconds === 3600 ? "1h" : `${preset.intervalSeconds / 60}min`;
  return `${preset.symbol} · ${interval} · ${preset.rangeStart.replace("T", " ")}`;
}

function chartViewportStart(items: KlinePoint[], count: number, focusTime?: string): number {
  if (!focusTime) return Math.max(0, items.length - count);
  const target = new Date(focusTime).getTime();
  const index = items.findIndex((item) => new Date(item.open_time).getTime() === target);
  if (index < 0) return Math.max(0, items.length - count);
  return Math.max(0, Math.min(items.length - count, index - Math.floor(count / 2)));
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

function profitClass(value: number): string {
  if (value > 0) return "profit-positive";
  if (value < 0) return "profit-negative";
  return "profit-neutral";
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

function CandlestickChart({ data, onLoadedRangeChange, signalTime }: {
  data: DailyKlineResult;
  onLoadedRangeChange: (range: LoadedKlineRange) => void;
  signalTime?: string;
}) {
  const [hoveredIndex, setHoveredIndex] = useState<number | null>(null);
  const [verticalZoom, setVerticalZoom] = useState(1);
  const [horizontalZoom, setHorizontalZoom] = useState(1);
  const desiredViewportCount = data.interval_seconds === 300 ? 112 : 64;
  const [allItems, setAllItems] = useState(data.items);
  const [hasMoreHistory, setHasMoreHistory] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(false);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const requestedViewportCount = Math.max(
    12,
    Math.round(desiredViewportCount / horizontalZoom)
  );
  const viewportCount = Math.min(allItems.length, requestedViewportCount);
  const [viewportStart, setViewportStart] = useState(() => chartViewportStart(allItems, viewportCount, signalTime));
  const dragRef = useRef<{ clientX: number; viewportStart: number } | null>(null);
  const chartRef = useRef<SVGSVGElement>(null);
  const loadingHistoryRef = useRef(false);
  const dataKeyRef = useRef(`${data.symbol}-${data.utc_trade_date}-${data.interval_seconds}`);
  dataKeyRef.current = `${data.symbol}-${data.utc_trade_date}-${data.interval_seconds}`;
  const maxViewportStart = Math.max(0, allItems.length - viewportCount);
  const safeViewportStart = Math.max(0, Math.min(maxViewportStart, viewportStart));
  const points = allItems.slice(safeViewportStart, safeViewportStart + viewportCount);
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
  const safeHoveredIndex = hoveredIndex === null
    ? null
    : Math.min(hoveredIndex, points.length - 1);
  const hovered = points[safeHoveredIndex ?? points.length - 1];
  const candleChangePercent = hovered.price_change_percent;
  const candleAmplitudePercent = hovered.amplitude_percent;
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
    setViewportStart(chartViewportStart(data.items, Math.min(data.items.length, desiredViewportCount), signalTime));
    setHasMoreHistory(true);
    setLoadingHistory(false);
    setHistoryError(null);
    loadingHistoryRef.current = false;
    setHoveredIndex(null);
    setVerticalZoom(1);
    setHorizontalZoom(1);
  }, [data, desiredViewportCount, signalTime]);

  useEffect(() => {
    if (allItems.length === 0) return;
    onLoadedRangeChange({
      firstOpenTime: allItems[0].open_time,
      lastCloseTime: allItems[allItems.length - 1].close_time,
      count: allItems.length,
    });
  }, [allItems, onLoadedRangeChange]);

  useEffect(() => {
    const chart = chartRef.current;
    if (!chart) return;
    const handleWheel = (event: WheelEvent) => {
      const bounds = chart.getBoundingClientRect();
      const svgX = (event.clientX - bounds.left) / bounds.width * width;
      const svgY = (event.clientY - bounds.top) / bounds.height * height;
      if (event.deltaY === 0) return;
      event.preventDefault();
      setHoveredIndex(null);
      const zoomFactor = Math.exp(-event.deltaY * 0.002);
      const isPriceAxis = svgX >= width - right && svgY >= top && svgY <= priceBottom;
      if (isPriceAxis) {
        setVerticalZoom((current) => Math.max(0.25, Math.min(8, current * zoomFactor)));
        return;
      }
      const anchorRatio = Math.max(0, Math.min(1, (svgX - left) / plotWidth));
      setHorizontalZoom((current) => {
        const next = Math.max(0.25, Math.min(8, current * zoomFactor));
        const nextCount = Math.min(
          allItems.length,
          Math.max(12, Math.round(desiredViewportCount / next))
        );
        const anchorIndex = safeViewportStart + Math.round(anchorRatio * (viewportCount - 1));
        setViewportStart(Math.max(0, Math.min(allItems.length - nextCount, anchorIndex - Math.round(anchorRatio * (nextCount - 1)))));
        if (safeViewportStart === 0 && Math.round(desiredViewportCount / next) > allItems.length) {
          void loadEarlier(false);
        }
        return next;
      });
    };
    chart.addEventListener("wheel", handleWheel, { passive: false });
    return () => chart.removeEventListener("wheel", handleWheel);
  }, [allItems.length, desiredViewportCount, height, left, plotWidth, priceBottom, right, safeViewportStart, viewportCount, width]);

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

  async function loadEarlier(preserveViewport = true) {
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
      setViewportStart((currentStart) => preserveViewport ? currentStart + earlier.length : 0);
      if (dragRef.current && preserveViewport) dragRef.current.viewportStart += earlier.length;
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

  function resetZoom() {
    setVerticalZoom(1);
    setHorizontalZoom(1);
    setViewportStart(chartViewportStart(allItems, Math.min(allItems.length, desiredViewportCount), signalTime));
  }

  return <>
    <div className="chart-readout">
      <span>{formatKlineTime(hovered.open_time)}</span>
      <span>开 <strong>{formatNumber(hovered.open_price, 8)}</strong></span>
      <span>高 <strong>{formatNumber(hovered.high_price, 8)}</strong></span>
      <span>低 <strong>{formatNumber(hovered.low_price, 8)}</strong></span>
      <span>收 <strong className={candleChangePercent >= 0 ? "candle-change-up" : "candle-change-down"}>{formatNumber(hovered.close_price, 8)}</strong></span>
      <span>涨跌幅 <strong className={candleChangePercent >= 0 ? "candle-change-up" : "candle-change-down"}>{candleChangePercent >= 0 ? "+" : ""}{formatNumber(candleChangePercent, 4)}%</strong></span>
      <span>振幅 <strong>{formatNumber(candleAmplitudePercent, 4)}%</strong></span>
      <span className="ema20-label">EMA20 <strong>{formatNumber(hovered.ema20, 8)}</strong></span>
      <span className="ema240-label">EMA240 <strong>{formatNumber(hovered.ema240, 8)}</strong></span>
      <span>成交额 <strong>{formatCompact(hovered.quote_volume)}</strong></span>
      {(hovered.open_interest_value !== null || hovered.open_interest_qty !== null) && <span>OI{hovered.open_interest_value !== null ? "价值" : "数量"} <strong>{formatCompact(hovered.open_interest_value ?? hovered.open_interest_qty)}</strong></span>}
      <button type="button" className="chart-axis-reset" onClick={resetZoom} title="恢复横轴和纵轴缩放">横轴 {Math.round(horizontalZoom * 100)}% · 纵轴 {Math.round(verticalZoom * 100)}%</button>
      <span className={`chart-drag-hint${historyError ? " chart-history-error" : ""}`}>{loadingHistory ? "正在加载更早K线…" : historyError ?? (!hasMoreHistory && safeViewportStart === 0 ? "已到最早K线" : "向右拖动持续回溯")} · 图表滚轮缩放时间轴 · 右侧价格轴滚轮缩放纵轴 · {safeViewportStart + 1}–{safeViewportStart + points.length} / {allItems.length}</span>
    </div>
    <div className="candlestick-chart-wrap">
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
      {signalTime && points.map((point, index) => {
        if (new Date(point.open_time).getTime() !== new Date(signalTime).getTime()) return null;
        const x = xAt(index);
        const tipY = Math.max(top + 20, yAt(point.high_price) - 3);
        const markerY = Math.max(top + 3, tipY - 28);
        return <g key={`signal-${point.open_time}`} className="chart-signal-marker" pointerEvents="none">
          <text x={x} y={markerY - 3} textAnchor="middle">命中</text>
          <line x1={x} x2={x} y1={markerY} y2={tipY - 7} />
          <polygon points={`${x - 6},${tipY - 8} ${x + 6},${tipY - 8} ${x},${tipY}`} />
        </g>;
      })}
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
      {safeHoveredIndex !== null && <g className="chart-crosshair">
        <line x1={xAt(safeHoveredIndex)} x2={xAt(safeHoveredIndex)} y1={top} y2={hasOi ? oiBottom : volumeBottom} />
        <line x1={left} x2={width - right} y1={yAt(points[safeHoveredIndex].close_price)} y2={yAt(points[safeHoveredIndex].close_price)} />
      </g>}
      </svg>
      {loadingHistory && <div className="chart-history-loader" role="status" aria-live="polite">
        <span className="chart-history-spinner" aria-hidden="true" />
        正在加载更早 K 线…
      </div>}
    </div>
  </>;
}

function KlineModal({ entry, onClose }: { entry: RankingEntry; onClose: () => void }) {
  const [data, setData] = useState<DailyKlineResult | null>(null);
  const [loadedRange, setLoadedRange] = useState<LoadedKlineRange | null>(null);
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
    setLoadedRange(null);
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
  const chartWindow = loadedRange
    ? formatKlineWindow(loadedRange.firstOpenTime, loadedRange.lastCloseTime)
    : formatLoadedKlineWindow(points, entry.utc_trade_date);
  return <div className="chart-modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="chart-modal" role="dialog" aria-modal="true" aria-labelledby="chart-modal-title">
      <header className="chart-modal-header">
        <div>
          <p className="eyebrow">本地时间 UTC+8 · {intervalSeconds / 60}分钟</p>
          <h2 id="chart-modal-title">{entry.symbol} <span>{chartWindow}</span></h2>
        </div>
        <div className="chart-modal-actions">
          <div className="chart-interval-switch" aria-label="K线周期">
            <button type="button" className={intervalSeconds === 300 ? "active" : ""} onClick={() => setIntervalSeconds(300)}>5min</button>
            <button type="button" className={intervalSeconds === 900 ? "active" : ""} onClick={() => setIntervalSeconds(900)}>15min</button>
          </div>
          <strong className={changeClass(entry.price_change)}>{entry.price_change >= 0 ? "+" : ""}{entry.price_change.toFixed(4)}%</strong>
          <button type="button" className="chart-close-button" onClick={onClose} aria-label="关闭K线图">×</button>
        </div>
      </header>
      {loading && <div className="chart-state">正在读取本地 K 线…</div>}
      {error && <div className="chart-state chart-state-error">K 线加载失败：{error}</div>}
      {data && data.items.length > 0 && <>
        <div className="chart-modal-body">
          <div className="chart-summary">
            <span>开盘 <strong>{formatNumber(first.open_price, 8)}</strong></span>
            <span>最高 <strong>{formatNumber(Math.max(...points.map((point) => point.high_price)), 8)}</strong></span>
            <span>最低 <strong>{formatNumber(Math.min(...points.map((point) => point.low_price)), 8)}</strong></span>
            <span>收盘 <strong>{formatNumber(last.close_price, 8)}</strong></span>
            <span>K线数量 <strong>{loadedRange?.count ?? points.length}</strong></span>
            <span className="ema20-label">━ EMA20</span>
            <span className="ema240-label">━ EMA240</span>
          </div>
          <CandlestickChart data={data} onLoadedRangeChange={setLoadedRange} />
          <p className="chart-footnote">图表时间统一显示为 UTC+8；从排行榜交易日开始展示本地数据库中最新的 VALID、已闭合 Trade K 线。15min 由 5min 数据聚合；EMA20/EMA240 使用前置数据预热；仅在本地存在有效观测时展示 OI。</p>
        </div>
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
    if (nextFilters.rankFrom === "" || nextFilters.rankTo === "") {
      setError("请填写完整的排名范围");
      return;
    }
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
          <label><span>排名从</span><input type="number" min="1" max="50" value={filters.rankFrom} onChange={(event) => setFilters({ ...filters, rankFrom: event.target.value === "" ? "" : Number(event.target.value) })} /></label>
          <label><span>排名至</span><input type="number" min="1" max="50" value={filters.rankTo} onChange={(event) => setFilters({ ...filters, rankTo: event.target.value === "" ? "" : Number(event.target.value) })} /></label>
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

const factorLabels: Record<FactorName, string> = {
  bullish_candle_sequence: "连续强势阳线",
  single_bar_price_rise: "单根 K 线快速拉升",
  volume_acceleration: "短周期成交量加速",
  ema_bullish_setup: "EMA 金叉/临近金叉",
  ema_bullish_cross: "EMA20 上穿 EMA240",
  rapid_price_rise: "价格快速拉升",
  open_interest_rise: "OI 价值快速提升",
  volume_surge: "成交量暴涨",
  amplitude_spike_streak: "连续振幅异常",
  low_average_amplitude: "7日平均振幅低"
};

const earlyBreakoutFactors: FactorName[] = ["bullish_candle_sequence", "single_bar_price_rise", "volume_acceleration", "ema_bullish_setup", "low_average_amplitude"];

function factorValue(name: FactorName, value: number | null): string {
  if (value === null) return "—";
  if (name === "ema_bullish_cross") return `${value} 根前`;
  if (name === "bullish_candle_sequence" || name === "single_bar_price_rise" || name === "ema_bullish_setup" || name === "rapid_price_rise" || name === "open_interest_rise" || name === "low_average_amplitude") return `${value.toFixed(2)}%`;
  return `${value.toFixed(2)}×`;
}

function SignalKlineModal({ signal, intervalSeconds, onClose }: { signal: BacktestSignal; intervalSeconds: BacktestInterval; onClose: () => void }) {
  const [result, setResult] = useState<BacktestKlineResult | null>(null);
  const [loadedRange, setLoadedRange] = useState<LoadedKlineRange | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    const params = new URLSearchParams({ symbol: signal.symbol, signal_time: signal.open_time, interval_seconds: String(intervalSeconds) });
    void fetch(`/api/backtests/klines?${params}`, { cache: "no-store", signal: controller.signal })
      .then(async (response) => {
        if (!response.ok) {
          const payload = await response.json().catch(() => null) as { detail?: string } | null;
          throw new Error(payload?.detail ?? `HTTP ${response.status}`);
        }
        return response.json() as Promise<BacktestKlineResult>;
      })
      .then(setResult)
      .catch((reason: unknown) => {
        if (reason instanceof DOMException && reason.name === "AbortError") return;
        setError(reason instanceof Error ? reason.message : "无法读取信号 K 线");
      });
    return () => controller.abort();
  }, [intervalSeconds, signal]);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [onClose]);

  const chartData = useMemo<DailyKlineResult | null>(() => result ? {
      symbol: result.symbol,
      utc_trade_date: result.signal_time.slice(0, 10),
      price_type: "TRADE",
      interval_seconds: result.interval_seconds,
      items: result.items
    } : null,
  [result]);
  const rangeText = loadedRange
    ? formatKlineWindow(loadedRange.firstOpenTime, loadedRange.lastCloseTime)
    : result && result.items.length > 0
      ? formatKlineWindow(result.items[0].open_time, result.items[result.items.length - 1].close_time)
      : "读取中…";

  return <div className="chart-modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="chart-modal" role="dialog" aria-modal="true" aria-labelledby="signal-chart-title">
      <header className="chart-modal-header">
        <div><p className="eyebrow">策略信号 · UTC+8 · {intervalSeconds / 60}分钟</p><h2 id="signal-chart-title">{signal.symbol} <span>{rangeText}</span></h2></div>
        <div className="chart-modal-actions"><strong className="signal-time-badge">命中 {formatKlineTime(signal.open_time)}</strong><button type="button" className="chart-close-button" onClick={onClose} aria-label="关闭K线图">×</button></div>
      </header>
      {!result && !error && <div className="chart-state">正在读取本地 {intervalSeconds / 60}min K 线…</div>}
      {error && <div className="chart-state chart-state-error">K 线加载失败：{error}</div>}
      {chartData && chartData.items.length > 0 && <div className="chart-modal-body">
        <div className="chart-summary"><span>命中时间 <strong>{formatKlineTime(signal.open_time)}</strong></span><span>命中收盘价 <strong>{formatNumber(signal.close_price, 8)}</strong></span><span>K线数量 <strong>{loadedRange?.count ?? chartData.items.length}</strong></span><span className="ema20-label">━ EMA20</span><span className="ema240-label">━ EMA240</span></div>
        <CandlestickChart data={chartData} signalTime={signal.open_time} onLoadedRangeChange={setLoadedRange} />
        <p className="chart-footnote">橙色箭头标记命中 K 线；数据直接读取本地 {intervalSeconds / 60}min K 线和同周期 EMA 指标，图表时间统一显示为 UTC+8。</p>
      </div>}
    </section>
  </div>;
}

function BacktestWorkspace() {
  const [metadata, setMetadata] = useState<BacktestMetadata | null>(null);
  const [savedStrategies, setSavedStrategies] = useState<SavedBacktestStrategy[]>([]);
  const [selectedStrategyId, setSelectedStrategyId] = useState("");
  const [strategyName, setStrategyName] = useState("");
  const [strategyDescription, setStrategyDescription] = useState("");
  const [savingStrategy, setSavingStrategy] = useState(false);
  const [strategyMessage, setStrategyMessage] = useState<string | null>(null);
  const [intervalSeconds, setIntervalSeconds] = useState<BacktestInterval>(900);
  const [startAt, setStartAt] = useState("");
  const [endAt, setEndAt] = useState("");
  const [allSymbols, setAllSymbols] = useState(false);
  const [selectedSymbols, setSelectedSymbols] = useState<string[]>([]);
  const [symbolSearch, setSymbolSearch] = useState("");
  const [generateLog, setGenerateLog] = useState(false);
  const [preserveLogHistory, setPreserveLogHistory] = useState(false);
  const [selectedFactors, setSelectedFactors] = useState<FactorName[]>(earlyBreakoutFactors);
  const [parameters, setParameters] = useState<BacktestParameterValues>({ ...defaultBacktestParameters });
  const [jobId, setJobId] = useState<string | null>(null);
  const [job, setJob] = useState<BacktestJob | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [chartSignal, setChartSignal] = useState<{ signal: BacktestSignal; intervalSeconds: BacktestInterval } | null>(null);

  useEffect(() => {
    void fetch("/api/backtests/metadata", { cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json() as Promise<BacktestMetadata>;
      })
      .then(setMetadata)
      .catch((reason: unknown) => setError(reason instanceof Error ? reason.message : "无法读取回测数据范围"));
  }, []);

  useEffect(() => {
    void fetch("/api/backtests/strategies", { cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json() as Promise<SavedBacktestStrategy[]>;
      })
      .then(setSavedStrategies)
      .catch((reason: unknown) => setError(reason instanceof Error ? reason.message : "无法读取已保存策略"));
  }, []);

  useEffect(() => {
    const intervalMetadata = metadata?.intervals[String(intervalSeconds) as "300" | "900"];
    if (!intervalMetadata?.available_to) return;
    const availableEnd = new Date(intervalMetadata.available_to);
    const exclusiveEnd = new Date(availableEnd.getTime() + intervalSeconds * 1000);
    const candidateStart = new Date(exclusiveEnd.getTime() - 7 * 24 * 60 * 60 * 1000);
    const minimumStart = intervalMetadata.available_from ? new Date(intervalMetadata.available_from) : candidateStart;
    setStartAt(toUtc8Input((candidateStart < minimumStart ? minimumStart : candidateStart).toISOString()));
    setEndAt(toUtc8Input(exclusiveEnd.toISOString()));
    setSelectedSymbols((current) => current.filter((symbol) => intervalMetadata.symbols.includes(symbol)));
  }, [intervalSeconds, metadata]);

  useEffect(() => {
    if (!jobId) return;
    let stopped = false;
    let timer = 0;
    const poll = async () => {
      try {
        const response = await fetch(`/api/backtests/${jobId}`, { cache: "no-store" });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const value = await response.json() as BacktestJob;
        if (stopped) return;
        setJob(value);
        if (value.status === "QUEUED" || value.status === "RUNNING") {
          timer = window.setTimeout(() => void poll(), 1200);
        } else {
          setSubmitting(false);
          if (value.status === "FAILED") setError(value.error ?? "回测失败");
        }
      } catch (reason) {
        if (!stopped) {
          setSubmitting(false);
          setError(reason instanceof Error ? reason.message : "无法读取回测进度");
        }
      }
    };
    void poll();
    return () => { stopped = true; window.clearTimeout(timer); };
  }, [jobId]);

  function setNumeric<Key extends keyof BacktestParameterValues>(key: Key, value: string) {
    setParameters((current) => ({ ...current, [key]: value === "" ? "" : Number(value) }));
  }

  function toggleFactor(name: FactorName) {
    setSelectedFactors((current) => current.includes(name) ? current.filter((item) => item !== name) : [...current, name]);
  }

  function toggleSymbol(symbol: string) {
    setSelectedSymbols((current) => current.includes(symbol) ? current.filter((item) => item !== symbol) : [...current, symbol]);
  }

  function configurationError(): string | null {
    if (selectedFactors.length === 0) return "请至少选择一个策略因子";
    const missingParameter = [...requiredBacktestParameterKeys(selectedFactors)].find((key) => parameters[key] === "");
    return missingParameter ? `请填写${backtestParameterLabels[missingParameter]}` : null;
  }

  function loadStrategy(strategyId: string) {
    setSelectedStrategyId(strategyId);
    setError(null);
    setStrategyMessage(null);
    if (!strategyId) {
      setStrategyName("");
      setStrategyDescription("");
      return;
    }
    const strategy = savedStrategies.find((item) => item.strategy_id === strategyId);
    if (!strategy) return;
    setStrategyName(strategy.name);
    setStrategyDescription(strategy.description);
    setIntervalSeconds(strategy.interval_seconds);
    setSelectedFactors([...strategy.parameters.required_factors]);
    setParameters(parameterValuesFromPayload(strategy.parameters));
    setStrategyMessage(`已加载策略“${strategy.name}”`);
  }

  async function saveStrategy() {
    const normalizedName = strategyName.trim();
    if (!normalizedName) { setError("请填写策略名称"); return; }
    const invalidConfiguration = configurationError();
    if (invalidConfiguration) { setError(invalidConfiguration); return; }
    setSavingStrategy(true);
    setError(null);
    setStrategyMessage(null);
    try {
      const response = await fetch(selectedStrategyId ? `/api/backtests/strategies/${selectedStrategyId}` : "/api/backtests/strategies", {
        method: selectedStrategyId ? "PUT" : "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: normalizedName,
          description: strategyDescription,
          interval_seconds: intervalSeconds,
          parameters: buildBacktestParameterPayload(parameters, selectedFactors)
        })
      });
      if (!response.ok) {
        const payload = await response.json().catch(() => null) as { detail?: string } | null;
        throw new Error(payload?.detail ?? `HTTP ${response.status}`);
      }
      const saved = await response.json() as SavedBacktestStrategy;
      setSavedStrategies((current) => [saved, ...current.filter((item) => item.strategy_id !== saved.strategy_id)]);
      setSelectedStrategyId(saved.strategy_id);
      setStrategyName(saved.name);
      setStrategyDescription(saved.description);
      setStrategyMessage(`策略“${saved.name}”已保存`);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "无法保存策略");
    } finally {
      setSavingStrategy(false);
    }
  }

  async function deleteStrategy() {
    if (!selectedStrategyId) return;
    const strategy = savedStrategies.find((item) => item.strategy_id === selectedStrategyId);
    if (!strategy || !window.confirm(`确认删除策略“${strategy.name}”？`)) return;
    setSavingStrategy(true);
    setError(null);
    setStrategyMessage(null);
    try {
      const response = await fetch(`/api/backtests/strategies/${selectedStrategyId}`, { method: "DELETE" });
      if (!response.ok) {
        const payload = await response.json().catch(() => null) as { detail?: string } | null;
        throw new Error(payload?.detail ?? `HTTP ${response.status}`);
      }
      setSavedStrategies((current) => current.filter((item) => item.strategy_id !== selectedStrategyId));
      setSelectedStrategyId("");
      setStrategyName("");
      setStrategyDescription("");
      setStrategyMessage(`策略“${strategy.name}”已删除`);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "无法删除策略");
    } finally {
      setSavingStrategy(false);
    }
  }

  async function runBacktest(event: React.FormEvent) {
    event.preventDefault();
    if (!startAt || !endAt) { setError("请选择回测开始和结束时间"); return; }
    const invalidConfiguration = configurationError();
    if (invalidConfiguration) { setError(invalidConfiguration); return; }
    if (!allSymbols && selectedSymbols.length === 0) { setError("请选择至少一个 Ticker，或选择全部 Tickers"); return; }
    setSubmitting(true);
    setJob(null);
    setJobId(null);
    setError(null);
    try {
      const response = await fetch("/api/backtests", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          start_at: utc8InputToIso(startAt),
          end_at: utc8InputToIso(endAt),
          interval_seconds: intervalSeconds,
          generate_log: generateLog,
          preserve_log_history: preserveLogHistory,
          symbols: allSymbols ? [] : selectedSymbols,
          parameters: buildBacktestParameterPayload(parameters, selectedFactors)
        })
      });
      if (!response.ok) {
        const payload = await response.json().catch(() => null) as { detail?: string | Array<{ msg: string }> } | null;
        const detail = Array.isArray(payload?.detail) ? payload.detail.map((item) => item.msg).join("；") : payload?.detail;
        throw new Error(detail ?? `HTTP ${response.status}`);
      }
      const created = await response.json() as { job_id: string };
      setJobId(created.job_id);
    } catch (reason) {
      setSubmitting(false);
      setError(reason instanceof Error ? reason.message : "无法启动回测");
    }
  }

  const intervalMetadata = metadata?.intervals[String(intervalSeconds) as "300" | "900"];
  const filteredSymbols = intervalMetadata?.symbols.filter((symbol) => symbol.includes(symbolSearch.trim().toUpperCase())) ?? [];
  const progress = job?.total_instruments ? job.scanned_instruments / job.total_instruments * 100 : 0;
  const visibleFactors = job?.request.parameters.required_factors ?? selectedFactors;

  return <main className="backtest-page">
    <header className="topbar ranking-header">
      <div><p className="brand-mark">STRATEGY LAB</p><h1>{intervalSeconds / 60}min 策略配置回测</h1><p className="subtitle">组合策略因子 · 指定 K 线周期、Tickers 与时间范围 · 双击信号定位命中 K 线</p></div>
      <div className="data-range-badge"><span>本地 {intervalSeconds / 60}min 数据范围</span><strong>{intervalMetadata?.available_from && intervalMetadata.available_to ? `${formatKlineTime(intervalMetadata.available_from)} → ${formatKlineTime(intervalMetadata.available_to)}` : "读取中…"}</strong></div>
    </header>
    {error && <div className="alert alert-critical">{error}</div>}
    <form className="backtest-layout" onSubmit={(event) => void runBacktest(event)}>
      <section className="panel backtest-config">
        <div className="panel-heading"><div><p className="eyebrow">CONFIGURATION</p><h3>回测条件</h3></div><span className="message">时间均为 UTC+8，结束时间不包含在筛选范围内</span></div>
        <div className="saved-strategy-panel">
          <div className="saved-strategy-picker">
            <label><span>已保存策略</span><select value={selectedStrategyId} onChange={(event) => loadStrategy(event.target.value)}><option value="">新建策略（当前配置）</option>{savedStrategies.map((strategy) => <option key={strategy.strategy_id} value={strategy.strategy_id}>{strategy.name}</option>)}</select></label>
            <button type="button" className="secondary-button" onClick={() => loadStrategy("")} disabled={savingStrategy}>新建</button>
          </div>
          <div className="saved-strategy-fields">
            <label><span>策略名称</span><input type="text" maxLength={120} placeholder="例如：BR 提前突破信号 v1" value={strategyName} onChange={(event) => setStrategyName(event.target.value)} /></label>
            <label><span>策略描述</span><textarea maxLength={2000} rows={2} placeholder="记录策略目标、适用行情或本次参数调整理由" value={strategyDescription} onChange={(event) => setStrategyDescription(event.target.value)} /></label>
          </div>
          <div className="saved-strategy-actions">
            <button type="button" className="primary-button" onClick={() => void saveStrategy()} disabled={savingStrategy}>{savingStrategy ? "处理中…" : selectedStrategyId ? "更新策略" : "保存策略"}</button>
            <button type="button" className="danger-button" onClick={() => void deleteStrategy()} disabled={savingStrategy || !selectedStrategyId}>删除策略</button>
            <small>保存 K 线周期、已选因子及因子参数，不保存时间范围和 Tickers。</small>
          </div>
          {strategyMessage && <p className="saved-strategy-message">{strategyMessage}</p>}
        </div>
        <div className="backtest-interval-row"><span>K 线周期</span><div className="backtest-interval-switch"><button type="button" className={intervalSeconds === 300 ? "active" : ""} onClick={() => setIntervalSeconds(300)}>5min</button><button type="button" className={intervalSeconds === 900 ? "active" : ""} onClick={() => setIntervalSeconds(900)}>15min</button></div><small>所有 EMA、价格、OI、成交量和振幅因子均按所选周期计算</small></div>
        <div className="backtest-time-grid">
          <label><span>开始时间</span><input type="datetime-local" value={startAt} onChange={(event) => setStartAt(event.target.value)} /></label>
          <label><span>结束时间（不含）</span><input type="datetime-local" value={endAt} onChange={(event) => setEndAt(event.target.value)} /></label>
          <label><span>均值周期（天）</span><input type="number" min="1" max="30" value={parameters.averageDays} onChange={(event) => setNumeric("averageDays", event.target.value)} /></label>
        </div>
        <div className="factor-grid">
          <fieldset className={selectedFactors.includes("bullish_candle_sequence") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("bullish_candle_sequence")} onChange={() => toggleFactor("bullish_candle_sequence")} /><strong>{factorLabels.bullish_candle_sequence}</strong></label><div className="factor-params"><label><span>连续阳线</span><input type="number" min="2" max="10" value={parameters.bullishSequenceBars} onChange={(event) => setNumeric("bullishSequenceBars", event.target.value)} /></label><label><span>前序收盘位置 ≥ %</span><input type="number" min="0" max="100" step="0.01" value={parameters.bullishMinClosePositionPercent} onChange={(event) => setNumeric("bullishMinClosePositionPercent", event.target.value)} /></label><label><span>最后收盘位置 ≥ %</span><input type="number" min="0" max="100" step="0.01" value={parameters.bullishLastClosePositionPercent} onChange={(event) => setNumeric("bullishLastClosePositionPercent", event.target.value)} /></label><label><span>最后上影线 ≤ %</span><input type="number" min="0" max="100" step="0.01" value={parameters.bullishLastMaxUpperShadowPercent} onChange={(event) => setNumeric("bullishLastMaxUpperShadowPercent", event.target.value)} /></label></div></fieldset>
          <fieldset className={selectedFactors.includes("single_bar_price_rise") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("single_bar_price_rise")} onChange={() => toggleFactor("single_bar_price_rise")} /><strong>{factorLabels.single_bar_price_rise}</strong></label><label><span>实体涨幅 ≥ %</span><input type="number" min="0" step="0.01" value={parameters.singleBarPriceRisePercent} onChange={(event) => setNumeric("singleBarPriceRisePercent", event.target.value)} /></label></fieldset>
          <fieldset className={selectedFactors.includes("volume_acceleration") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("volume_acceleration")} onChange={() => toggleFactor("volume_acceleration")} /><strong>{factorLabels.volume_acceleration}</strong></label><div className="factor-params"><label><span>均值窗口 K 根</span><input type="number" min="2" max="2016" value={parameters.volumeAccelerationAverageBars} onChange={(event) => setNumeric("volumeAccelerationAverageBars", event.target.value)} /></label><label><span>均值倍数 ≥</span><input type="number" min="0" step="0.01" value={parameters.volumeAccelerationAverageMultiple} onChange={(event) => setNumeric("volumeAccelerationAverageMultiple", event.target.value)} /></label><label><span>上一根倍数 ≥</span><input type="number" min="0" step="0.01" value={parameters.volumeAccelerationPreviousMultiple} onChange={(event) => setNumeric("volumeAccelerationPreviousMultiple", event.target.value)} /></label></div></fieldset>
          <fieldset className={selectedFactors.includes("ema_bullish_setup") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("ema_bullish_setup")} onChange={() => toggleFactor("ema_bullish_setup")} /><strong>{factorLabels.ema_bullish_setup}</strong></label><div className="factor-params"><label><span>临近差距 ≤ %</span><input type="number" min="0" max="100" step="0.01" value={parameters.emaNearCrossGapPercent} onChange={(event) => setNumeric("emaNearCrossGapPercent", event.target.value)} /></label><label><span>差距收缩 ≥ %</span><input type="number" min="0" max="100" step="0.01" value={parameters.emaGapShrinkMinPercent} onChange={(event) => setNumeric("emaGapShrinkMinPercent", event.target.value)} /></label></div></fieldset>
          <fieldset className={selectedFactors.includes("ema_bullish_cross") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("ema_bullish_cross")} onChange={() => toggleFactor("ema_bullish_cross")} /><strong>{factorLabels.ema_bullish_cross}</strong></label><label><span>上穿发生于最近 K 根</span><input type="number" min="1" max="96" value={parameters.emaCrossBars} onChange={(event) => setNumeric("emaCrossBars", event.target.value)} /></label></fieldset>
          <fieldset className={selectedFactors.includes("rapid_price_rise") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("rapid_price_rise")} onChange={() => toggleFactor("rapid_price_rise")} /><strong>{factorLabels.rapid_price_rise}</strong></label><div className="factor-params"><label><span>窗口 K 根</span><input type="number" min="1" max="96" value={parameters.priceWindowBars} onChange={(event) => setNumeric("priceWindowBars", event.target.value)} /></label><label><span>涨幅 ≥ %</span><input type="number" min="0" step="0.01" value={parameters.priceRisePercent} onChange={(event) => setNumeric("priceRisePercent", event.target.value)} /></label></div></fieldset>
          <fieldset className={selectedFactors.includes("open_interest_rise") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("open_interest_rise")} onChange={() => toggleFactor("open_interest_rise")} /><strong>{factorLabels.open_interest_rise}</strong></label><div className="factor-params"><label><span>窗口 K 根</span><input type="number" min="1" max="96" value={parameters.oiWindowBars} onChange={(event) => setNumeric("oiWindowBars", event.target.value)} /></label><label><span>涨幅 ≥ %</span><input type="number" min="0" step="0.01" value={parameters.oiRisePercent} onChange={(event) => setNumeric("oiRisePercent", event.target.value)} /></label></div></fieldset>
          <fieldset className={selectedFactors.includes("volume_surge") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("volume_surge")} onChange={() => toggleFactor("volume_surge")} /><strong>{factorLabels.volume_surge}</strong></label><label><span>当前成交额 ≥ 均值倍数</span><input type="number" min="0" step="0.1" value={parameters.volumeMultiple} onChange={(event) => setNumeric("volumeMultiple", event.target.value)} /></label></fieldset>
          <fieldset className={selectedFactors.includes("amplitude_spike_streak") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("amplitude_spike_streak")} onChange={() => toggleFactor("amplitude_spike_streak")} /><strong>{factorLabels.amplitude_spike_streak}</strong></label><div className="factor-params"><label><span>振幅 ≥ 均值倍数</span><input type="number" min="0" step="0.1" value={parameters.amplitudeMultiple} onChange={(event) => setNumeric("amplitudeMultiple", event.target.value)} /></label><label><span>连续 K 根</span><input type="number" min="1" max="96" value={parameters.amplitudeConsecutiveBars} onChange={(event) => setNumeric("amplitudeConsecutiveBars", event.target.value)} /></label></div></fieldset>
          <fieldset className={selectedFactors.includes("low_average_amplitude") ? "factor-card enabled" : "factor-card"}><label className="factor-toggle"><input type="checkbox" checked={selectedFactors.includes("low_average_amplitude")} onChange={() => toggleFactor("low_average_amplitude")} /><strong>{factorLabels.low_average_amplitude}</strong></label><label><span>周期均值 &lt; %</span><input type="number" min="0" step="0.01" value={parameters.averageAmplitudeMaxPercent} onChange={(event) => setNumeric("averageAmplitudeMaxPercent", event.target.value)} /></label></fieldset>
        </div>
      </section>
      <aside className="panel ticker-picker">
        <div className="panel-heading"><div><p className="eyebrow">UNIVERSE</p><h3>Tickers</h3></div><strong>{allSymbols ? `全部 ${intervalMetadata?.symbols.length ?? 0}` : `已选 ${selectedSymbols.length}`}</strong></div>
        <label className="ticker-all"><input type="checkbox" checked={allSymbols} onChange={(event) => setAllSymbols(event.target.checked)} /><span>全部 Tickers</span></label>
        <input type="search" placeholder="搜索 BTCUSDT" value={symbolSearch} onChange={(event) => setSymbolSearch(event.target.value)} disabled={allSymbols} />
        <div className="ticker-list" aria-disabled={allSymbols}>{filteredSymbols.map((symbol) => <label key={symbol}><input type="checkbox" checked={selectedSymbols.includes(symbol)} disabled={allSymbols} onChange={() => toggleSymbol(symbol)} /><span>{symbol}</span></label>)}</div>
        <label className="backtest-log-option"><input type="checkbox" checked={generateLog} onChange={(event) => setGenerateLog(event.target.checked)} /><span>生成逐 K 线 HTML 日志</span></label>
        <label className="backtest-log-option"><input type="checkbox" checked={preserveLogHistory} onChange={(event) => setPreserveLogHistory(event.target.checked)} /><span>不删除历史日志</span></label>
        <button className="primary-button backtest-run" type="submit" disabled={submitting || !metadata}>{submitting ? "回测运行中…" : "开始回测"}</button>
        <p className="message">日志默认不生成，新回测默认删除历史日志；勾选“不删除历史日志”可保留。单份日志最多记录 100,000 根 K 线；选择的因子采用 AND 关系。</p>
      </aside>
    </form>
    <section className="panel backtest-results">
      <div className="panel-heading"><div><p className="eyebrow">SIGNALS</p><h3>命中信号</h3></div><div className="backtest-result-meta"><strong>{job?.signal_count.toLocaleString() ?? 0} 条</strong><span>{job?.status === "COMPLETED" ? "回测完成" : job?.status === "FAILED" ? "回测失败" : job ? `${job.scanned_instruments} / ${job.total_instruments} Tickers` : "等待回测"}</span></div></div>
      {job && (job.status === "QUEUED" || job.status === "RUNNING") && <div className="backtest-progress"><span style={{ width: `${progress}%` }} /></div>}
      {job?.truncated && <div className="alert">结果已达到 {job.max_signals.toLocaleString()} 条上限，请缩短时间范围、收紧参数或减少 Tickers。</div>}
      {job?.request.generate_log && <div className={`backtest-log-status${job.log_truncated ? " truncated" : ""}`}><span>诊断日志：{job.log_line_count.toLocaleString()} 根 K 线{job.log_truncated ? `（已达到 ${job.max_log_lines.toLocaleString()} 条上限）` : ""}</span>{job.log_available && job.log_url && (job.status === "COMPLETED" || job.status === "FAILED") && <a href={job.log_url} target="_blank" rel="noopener noreferrer">浏览 HTML 日志 ↗</a>}</div>}
      <p className="backtest-list-hint">双击任一信号，在 {job ? job.request.interval_seconds / 60 : intervalSeconds / 60}min K 线图中查看橙色箭头标记。</p>
      <div className="table-scroll backtest-signal-scroll"><table className="storage-table backtest-signal-table"><thead><tr><th>信号时间 UTC+8</th><th>Ticker</th><th>收盘价</th>{visibleFactors.map((name) => <th key={name}>{factorLabels[name]}</th>)}</tr></thead><tbody>
        {job?.signals.map((signal) => <tr key={`${signal.symbol}-${signal.open_time}`} tabIndex={0} onDoubleClick={() => setChartSignal({ signal, intervalSeconds: job.request.interval_seconds })} onKeyDown={(event) => { if (event.key === "Enter") setChartSignal({ signal, intervalSeconds: job.request.interval_seconds }); }}><td>{formatKlineTime(signal.open_time)}</td><td><strong>{signal.symbol}</strong></td><td>{formatNumber(signal.close_price, 8)}</td>{visibleFactors.map((name) => <td key={name} title={signal.factors[name].threshold}>{factorValue(name, signal.factors[name].value)}</td>)}</tr>)}
        {!submitting && (!job || job.signals.length === 0) && <tr><td className="empty-cell" colSpan={3 + visibleFactors.length}>{job?.status === "COMPLETED" ? "当前配置没有命中信号" : "配置策略后点击“开始回测”"}</td></tr>}
      </tbody></table></div>
    </section>
    {chartSignal && <SignalKlineModal signal={chartSignal.signal} intervalSeconds={chartSignal.intervalSeconds} onClose={() => setChartSignal(null)} />}
  </main>;
}

function PaperReplayChart({ candles, position, pendingOrders, intervalSeconds, sessionId, showOpeningRange, showUpperOpeningRange, showLowerOpeningRange, onCancelPendingOrder, cancellingOrder }: {
  candles: PaperChartPoint[];
  position: PaperPosition | null;
  pendingOrders: PaperPendingOrder[];
  intervalSeconds: number;
  sessionId: string;
  showOpeningRange: boolean;
  showUpperOpeningRange: boolean;
  showLowerOpeningRange: boolean;
  onCancelPendingOrder: (orderId: string) => void;
  cancellingOrder: boolean;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const candleSeriesRef = useRef<ISeriesApi<"Candlestick"> | null>(null);
  const volumeSeriesRef = useRef<ISeriesApi<"Histogram"> | null>(null);
  const ema20SeriesRef = useRef<ISeriesApi<"Line"> | null>(null);
  const ema240SeriesRef = useRef<ISeriesApi<"Line"> | null>(null);
  const chartPointsRef = useRef<PaperChartPoint[]>(candles);
  const pendingOrdersRef = useRef<PaperPendingOrder[]>(pendingOrders);
  const refreshTimeAxisRef = useRef<() => void>(() => undefined);
  const refreshOpeningRangeOverlayRef = useRef<() => void>(() => undefined);
  const refreshOrderControlsRef = useRef<() => void>(() => undefined);
  const positionLinesRef = useRef<IPriceLine[]>([]);
  const visiblePendingOrderIdsRef = useRef<string[]>([]);
  const loadedSessionRef = useRef<string | null>(null);
  const loadedCountRef = useRef(0);
  const followingLatestRef = useRef(true);
  const [hoveredCandle, setHoveredCandle] = useState<PaperCandleReadout | null>(null);
  const [timeAxisLabels, setTimeAxisLabels] = useState<PaperTimeAxisLabel[]>([]);
  const [openingRangeOverlay, setOpeningRangeOverlay] = useState<PaperOpeningRangeOverlay | null>(null);
  const [orderControls, setOrderControls] = useState<PaperOrderControl[]>([]);
  const visibleCapacity = intervalSeconds === 300 ? 112 : 64;
  const points = candles;
  const initialLatestPosition = .8;
  const initialCandleHeightRatio = .1;
  chartPointsRef.current = candles;
  pendingOrdersRef.current = pendingOrders;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const chart = createChart(container, {
      autoSize: true,
      layout: {
        background: { type: ColorType.Solid, color: "#071522" },
        textColor: "#71899f",
        fontFamily: "Inter, ui-sans-serif, sans-serif",
        attributionLogo: true,
      },
      grid: {
        vertLines: { color: "#182c3e" },
        horzLines: { color: "#182c3e" },
      },
      rightPriceScale: { borderColor: "#29455e", scaleMargins: { top: .08, bottom: .22 } },
      timeScale: {
        borderColor: "#29455e",
        timeVisible: true,
        secondsVisible: false,
        tickMarkFormatter: () => "",
        rightOffset: 5,
        barSpacing: 8,
        minBarSpacing: 4,
        fixLeftEdge: false,
        lockVisibleTimeRangeOnResize: true,
      },
      localization: {
        timeFormatter: (time: Time) => typeof time === "number"
          ? formatKlineTime(new Date(time * 1000).toISOString())
          : typeof time === "string"
            ? time
            : `${time.year}-${String(time.month).padStart(2, "0")}-${String(time.day).padStart(2, "0")}`,
      },
      handleScale: {
        mouseWheel: true,
        pinch: true,
        axisPressedMouseMove: { time: true, price: true },
        axisDoubleClickReset: { time: true, price: true },
      },
      handleScroll: true,
    });
    const candleSeries = chart.addSeries(CandlestickSeries, {
      upColor: "#0ecb81",
      downColor: "#f6465d",
      wickUpColor: "#0ecb81",
      wickDownColor: "#f6465d",
      borderVisible: false,
      priceFormat: { type: "price", precision: 2, minMove: .01 },
    });
    const volumeSeries = chart.addSeries(HistogramSeries, {
      priceScaleId: "",
      priceFormat: { type: "volume" },
      lastValueVisible: false,
      priceLineVisible: false,
    });
    const ema20Series = chart.addSeries(LineSeries, {
      color: "#e84a83",
      lineWidth: 1,
      priceLineVisible: false,
      lastValueVisible: false,
      crosshairMarkerVisible: false,
    });
    const ema240Series = chart.addSeries(LineSeries, {
      color: "#35b768",
      lineWidth: 1,
      priceLineVisible: false,
      lastValueVisible: false,
      crosshairMarkerVisible: false,
    });
    volumeSeries.priceScale().applyOptions({ scaleMargins: { top: .84, bottom: 0 } });
    const handlePriceScaleWheel = (event: WheelEvent) => {
      const priceScale = chart.priceScale("right");
      const scaleWidth = priceScale.width();
      const bounds = container.getBoundingClientRect();
      if (scaleWidth <= 0 || event.clientX - bounds.left < bounds.width - scaleWidth) return;
      const range = priceScale.getVisibleRange();
      if (!range) return;
      event.preventDefault();
      event.stopPropagation();
      const pointerPrice = candleSeries.coordinateToPrice(event.clientY - bounds.top);
      const anchor = pointerPrice ?? (range.from + range.to) / 2;
      const factor = event.deltaY > 0 ? 1.12 : .89;
      priceScale.setAutoScale(false);
      priceScale.setVisibleRange({
        from: anchor - (anchor - range.from) * factor,
        to: anchor + (range.to - anchor) * factor,
      });
      window.requestAnimationFrame(() => {
        refreshOpeningRangeOverlayRef.current();
        refreshOrderControlsRef.current();
      });
    };
    const handleCrosshairMove = (param: MouseEventParams<Time>) => {
      const candle = param.seriesData.get(candleSeries);
      if (typeof param.time !== "number" || !candle || !("open" in candle)) {
        setHoveredCandle(null);
        return;
      }
      const ema20 = param.seriesData.get(ema20Series);
      const ema240 = param.seriesData.get(ema240Series);
      setHoveredCandle({
        open_time: new Date(param.time * 1000).toISOString(),
        open_price: candle.open,
        high_price: candle.high,
        low_price: candle.low,
        close_price: candle.close,
        ema20: ema20 && "value" in ema20 ? ema20.value : null,
        ema240: ema240 && "value" in ema240 ? ema240.value : null,
      });
    };
    const handleVisibleRangeChange = (range: LogicalRange | null) => {
      if (!range || loadedCountRef.current === 0) return;
      followingLatestRef.current = range.to >= loadedCountRef.current - 1;
      refreshTimeAxisRef.current();
      refreshOpeningRangeOverlayRef.current();
      refreshOrderControlsRef.current();
    };
    const refreshTimeAxis = () => {
      const plotWidth = container.clientWidth - chart.priceScale("right").width();
      setTimeAxisLabels(chartPointsRef.current.flatMap((point, index) => {
        if (index % 3 !== 0) return [];
        const time = Math.floor(new Date(point.open_time).getTime() / 1000) as UTCTimestamp;
        const left = chart.timeScale().timeToCoordinate(time);
        if (left === null || left < 18 || left > plotWidth - 18) return [];
        return [{ key: point.open_time, left, text: formatPaperAxisTime(point.open_time) }];
      }));
    };
    refreshTimeAxisRef.current = refreshTimeAxis;
    const refreshOrderControls = () => {
      const priceScaleWidth = chart.priceScale("right").width();
      setOrderControls(pendingOrdersRef.current.flatMap((order) => {
        if (order.order_kind !== "CLOSE") return [];
        const coordinate = candleSeries.priceToCoordinate(order.price);
        if (coordinate === null || coordinate < 12 || coordinate > container.clientHeight - 26) return [];
        const isStopLoss = order.order_type === "STOP_MARKET";
        return [{
          orderId: order.order_id,
          top: coordinate,
          right: priceScaleWidth + 5,
          label: isStopLoss ? "取消止损委托" : "取消止盈委托",
          kind: isStopLoss ? "stop-loss" as const : "take-profit" as const,
        }];
      }));
    };
    refreshOrderControlsRef.current = refreshOrderControls;
    const resizeObserver = new ResizeObserver(() => {
      refreshTimeAxis();
      refreshOpeningRangeOverlayRef.current();
      refreshOrderControls();
    });
    const handlePointerMove = (event: PointerEvent) => {
      if (event.buttons !== 0) window.requestAnimationFrame(() => {
        refreshOpeningRangeOverlayRef.current();
        refreshOrderControlsRef.current();
      });
    };
    const handlePointerEnd = () => window.requestAnimationFrame(() => {
      refreshOpeningRangeOverlayRef.current();
      refreshOrderControlsRef.current();
    });
    resizeObserver.observe(container);
    container.addEventListener("wheel", handlePriceScaleWheel, { passive: false, capture: true });
    container.addEventListener("pointermove", handlePointerMove);
    container.addEventListener("pointerup", handlePointerEnd);
    container.addEventListener("dblclick", handlePointerEnd);
    chart.subscribeCrosshairMove(handleCrosshairMove);
    chart.timeScale().subscribeVisibleLogicalRangeChange(handleVisibleRangeChange);
    chartRef.current = chart;
    candleSeriesRef.current = candleSeries;
    volumeSeriesRef.current = volumeSeries;
    ema20SeriesRef.current = ema20Series;
    ema240SeriesRef.current = ema240Series;
    return () => {
      container.removeEventListener("wheel", handlePriceScaleWheel, true);
      container.removeEventListener("pointermove", handlePointerMove);
      container.removeEventListener("pointerup", handlePointerEnd);
      container.removeEventListener("dblclick", handlePointerEnd);
      chart.unsubscribeCrosshairMove(handleCrosshairMove);
      chart.timeScale().unsubscribeVisibleLogicalRangeChange(handleVisibleRangeChange);
      resizeObserver.disconnect();
      refreshTimeAxisRef.current = () => undefined;
      refreshOpeningRangeOverlayRef.current = () => undefined;
      refreshOrderControlsRef.current = () => undefined;
      chart.remove();
      chartRef.current = null;
      candleSeriesRef.current = null;
      volumeSeriesRef.current = null;
      ema20SeriesRef.current = null;
      ema240SeriesRef.current = null;
      setTimeAxisLabels([]);
      setOpeningRangeOverlay(null);
      setOrderControls([]);
      positionLinesRef.current = [];
      visiblePendingOrderIdsRef.current = [];
      loadedSessionRef.current = null;
      loadedCountRef.current = 0;
      followingLatestRef.current = true;
    };
  }, []);

  useEffect(() => setHoveredCandle(null), [sessionId]);

  useEffect(() => {
    const chart = chartRef.current;
    const candleSeries = candleSeriesRef.current;
    const volumeSeries = volumeSeriesRef.current;
    const ema20Series = ema20SeriesRef.current;
    const ema240Series = ema240SeriesRef.current;
    if (!chart || !candleSeries || !volumeSeries || !ema20Series || !ema240Series) return;
    const candleData = (point: PaperCandle) => ({
      time: Math.floor(new Date(point.open_time).getTime() / 1000) as UTCTimestamp,
      open: point.open_price,
      high: point.high_price,
      low: point.low_price,
      close: point.close_price,
    });
    const volumeData = (point: PaperCandle) => ({
      time: Math.floor(new Date(point.open_time).getTime() / 1000) as UTCTimestamp,
      value: point.quote_volume,
      color: point.close_price >= point.open_price ? "rgba(14,203,129,.38)" : "rgba(246,70,93,.38)",
    });
    const emaData = (point: PaperChartPoint, value: number | null) => value === null ? null : ({
      time: Math.floor(new Date(point.open_time).getTime() / 1000) as UTCTimestamp,
      value,
    });
    if (loadedSessionRef.current !== sessionId || points.length < loadedCountRef.current) {
      candleSeries.setData(points.map(candleData));
      volumeSeries.setData(points.map(volumeData));
      ema20Series.setData(points.map((point) => emaData(point, point.ema20)).filter((point) => point !== null));
      ema240Series.setData(points.map((point) => emaData(point, point.ema240)).filter((point) => point !== null));
      loadedSessionRef.current = sessionId;
      loadedCountRef.current = points.length;
      followingLatestRef.current = true;
      const lowestPrice = Math.min(...points.map((point) => point.low_price));
      const highestPrice = Math.max(...points.map((point) => point.high_price));
      const priceCenter = (lowestPrice + highestPrice) / 2;
      const observedPriceSpan = highestPrice - lowestPrice;
      const minimumPriceSpan = Math.max(Math.abs(priceCenter) * .0001, .01);
      const visiblePriceSpan = Math.max(observedPriceSpan, minimumPriceSpan) / initialCandleHeightRatio;
      const priceScale = chart.priceScale("right");
      priceScale.setAutoScale(false);
      priceScale.setVisibleRange({
        from: priceCenter - visiblePriceSpan / 2,
        to: priceCenter + visiblePriceSpan / 2,
      });
      const latestIndex = points.length - 1;
      const logicalRangeFrom = latestIndex - visibleCapacity * initialLatestPosition;
      chart.timeScale().setVisibleLogicalRange({
        from: logicalRangeFrom,
        to: logicalRangeFrom + visibleCapacity,
      });
      window.requestAnimationFrame(() => {
        refreshTimeAxisRef.current();
        refreshOrderControlsRef.current();
      });
      return;
    }
    if (points.length === loadedCountRef.current) return;

    const visibleRange = chart.timeScale().getVisibleLogicalRange();
    const followingLatest = followingLatestRef.current;
    const priceScale = chart.priceScale("right");
    const preservePriceRange = !priceScale.options().autoScale;
    const priceRange = preservePriceRange ? priceScale.getVisibleRange() : null;
    const addedCount = points.length - loadedCountRef.current;
    for (const point of points.slice(loadedCountRef.current)) {
      candleSeries.update(candleData(point));
      volumeSeries.update(volumeData(point));
      const ema20 = emaData(point, point.ema20);
      const ema240 = emaData(point, point.ema240);
      if (ema20) ema20Series.update(ema20);
      if (ema240) ema240Series.update(ema240);
    }
    loadedCountRef.current = points.length;
    if (followingLatest && visibleRange) {
      chart.timeScale().setVisibleLogicalRange({
        from: visibleRange.from + addedCount,
        to: visibleRange.to + addedCount,
      });
    }
    if (priceRange) {
      priceScale.setAutoScale(false);
      priceScale.setVisibleRange(priceRange);
    }
    window.requestAnimationFrame(() => {
      refreshTimeAxisRef.current();
      refreshOrderControlsRef.current();
    });
  }, [points, sessionId, visibleCapacity]);

  useEffect(() => {
    const series = candleSeriesRef.current;
    const chart = chartRef.current;
    if (!series || !chart) return;
    for (const line of positionLinesRef.current) series.removePriceLine(line);
    positionLinesRef.current = [];
    const definitions = [
      ...(position === null ? [] : [{ price: position.entry_price, color: "#58d6c2", title: "开仓", style: LineStyle.Dashed }]),
      ...(position === null || position.liquidation_price <= 0 ? [] : [{ price: position.liquidation_price, color: "#ff6477", title: "强平", style: LineStyle.Dashed }]),
      ...pendingOrders.map((order) => ({
        price: order.price,
        color: order.order_type === "STOP_MARKET" ? "#ffb347" : order.order_kind === "OPEN" ? "#58a6ff" : "#0ecb81",
        title: order.order_type === "STOP_MARKET" ? "止损" : order.order_kind === "OPEN" ? `限价开${order.position_side === "LONG" ? "多" : "空"}` : "限价止盈",
        style: LineStyle.Dashed,
      })),
    ];
    positionLinesRef.current = definitions.map((definition) => series.createPriceLine({
      ...definition,
      lineWidth: 1,
      axisLabelVisible: true,
    }));
    const pendingOrderIds = pendingOrders.map((order) => order.order_id);
    const hasNewPendingOrder = pendingOrderIds.some((orderId) => !visiblePendingOrderIdsRef.current.includes(orderId));
    visiblePendingOrderIdsRef.current = pendingOrderIds;
    if (hasNewPendingOrder) {
      const priceScale = chart.priceScale("right");
      const visibleRange = priceScale.getVisibleRange();
      if (visibleRange) {
        const lowestOrderPrice = Math.min(...pendingOrders.map((order) => order.price));
        const highestOrderPrice = Math.max(...pendingOrders.map((order) => order.price));
        if (lowestOrderPrice < visibleRange.from || highestOrderPrice > visibleRange.to) {
          const rangeSpan = Math.max(visibleRange.to - visibleRange.from, highestOrderPrice - lowestOrderPrice);
          const padding = Math.max(rangeSpan * .08, highestOrderPrice * .001);
          priceScale.setAutoScale(false);
          priceScale.setVisibleRange({
            from: Math.min(visibleRange.from, lowestOrderPrice - padding),
            to: Math.max(visibleRange.to, highestOrderPrice + padding),
          });
          window.requestAnimationFrame(() => {
            refreshOpeningRangeOverlayRef.current();
            refreshOrderControlsRef.current();
          });
        }
      }
    }
    window.requestAnimationFrame(() => refreshOrderControlsRef.current());
  }, [position?.entry_price, position?.liquidation_price, pendingOrders]);

  useEffect(() => {
    const chart = chartRef.current;
    const series = candleSeriesRef.current;
    const container = containerRef.current;
    if (!chart || !series || !container) return;
    const openingRange = calculatePaperOpeningRange(points);
    if (!openingRange) {
      setOpeningRangeOverlay(null);
      refreshOpeningRangeOverlayRef.current = () => undefined;
      return;
    }
    const refreshOpeningRangeOverlay = () => {
      const trueRange = openingRange.high - openingRange.low;
      const startX = chart.timeScale().timeToCoordinate(Math.floor(openingRange.sessionStartMs / 1000) as UTCTimestamp);
      const endX = chart.timeScale().timeToCoordinate(Math.floor(openingRange.sessionEndMs / 1000) as UTCTimestamp);
      const latest = points[points.length - 1];
      const latestX = latest
        ? chart.timeScale().timeToCoordinate(Math.floor(new Date(latest.open_time).getTime() / 1000) as UTCTimestamp)
        : null;
      const highY = series.priceToCoordinate(openingRange.high);
      const lowY = series.priceToCoordinate(openingRange.low);
      const upperOneY = series.priceToCoordinate(openingRange.high + trueRange);
      const upperTwoY = series.priceToCoordinate(openingRange.high + trueRange * 2);
      const lowerOneY = series.priceToCoordinate(openingRange.low - trueRange);
      const lowerTwoY = series.priceToCoordinate(openingRange.low - trueRange * 2);
      if ([startX, latestX, highY, lowY, upperOneY, upperTwoY, lowerOneY, lowerTwoY].some((value) => value === null)) {
        setOpeningRangeOverlay(null);
        return;
      }
      const barSpacing = chart.timeScale().options().barSpacing;
      const rangeRight = openingRange.completed && endX !== null ? endX : latestX! + barSpacing / 2;
      setOpeningRangeOverlay({
        width: container.clientWidth,
        height: container.clientHeight,
        rangeLeft: startX!,
        rangeRight,
        projectionRight: Math.max(rangeRight, latestX! + barSpacing / 2),
        highY: highY!,
        lowY: lowY!,
        upperOneY: upperOneY!,
        upperTwoY: upperTwoY!,
        lowerOneY: lowerOneY!,
        lowerTwoY: lowerTwoY!,
        high: openingRange.high,
        low: openingRange.low,
        trueRange,
        completed: openingRange.completed,
      });
    };
    refreshOpeningRangeOverlayRef.current = refreshOpeningRangeOverlay;
    window.requestAnimationFrame(refreshOpeningRangeOverlay);
    return () => {
      if (refreshOpeningRangeOverlayRef.current === refreshOpeningRangeOverlay) {
        refreshOpeningRangeOverlayRef.current = () => undefined;
      }
    };
  }, [points, sessionId, showOpeningRange, showUpperOpeningRange, showLowerOpeningRange]);

  const current = hoveredCandle ?? points[points.length - 1];
  const candleChange = current ? current.close_price - current.open_price : null;
  const candleChangePercent = current && current.open_price > 0 ? candleChange! / current.open_price * 100 : null;
  const candleAmplitude = current && current.open_price > 0 ? (current.high_price - current.low_price) / current.open_price * 100 : null;
  const candleChangeClass = candleChange === null || candleChange >= 0 ? "candle-change-up" : "candle-change-down";
  return <div className="paper-chart-wrap">
    <div className="chart-readout">
      {current ? <><span>{formatKlineTime(current.open_time)}</span>
      <span>开 <strong>{formatNumber(current.open_price, 2)}</strong></span>
      <span>高 <strong>{formatNumber(current.high_price, 2)}</strong></span>
      <span>低 <strong>{formatNumber(current.low_price, 2)}</strong></span>
      <span>收 <strong className={candleChangeClass}>{formatNumber(current.close_price, 2)}</strong></span>
      <span className="paper-candle-stats" title="涨跌幅与涨跌值按开盘价至收盘价计算；振幅按最高价与最低价之差除以开盘价计算">
        <span>涨跌幅 <strong className={candleChangeClass}>{candleChangePercent === null ? "--" : `${candleChangePercent >= 0 ? "+" : ""}${candleChangePercent.toFixed(2)}%`}</strong></span>
        <span>振幅 <strong>{candleAmplitude === null ? "--" : `${candleAmplitude.toFixed(2)}%`}</strong></span>
        <span>涨跌值 <strong className={candleChangeClass}>{candleChange === null ? "--" : `${candleChange >= 0 ? "+" : ""}${formatNumber(candleChange, 2)}`}</strong></span>
      </span></> : <span>载入行情后开始回放</span>}
      {current && <span className="paper-ema-legend"><span>EMA20 <strong>{current.ema20 === null ? "--" : formatNumber(current.ema20, 2)}</strong></span><span>EMA240 <strong>{current.ema240 === null ? "--" : formatNumber(current.ema240, 2)}</strong></span></span>}
    </div>
    <div className="paper-chart-canvas">
      <div ref={containerRef} className="paper-lightweight-chart" role="img" aria-label="PaperTrader K线回放图" />
      <div className="paper-order-line-controls">
        {orderControls.map((control) => <button
          key={control.orderId}
          type="button"
          className={control.kind}
          style={{ top: control.top, right: control.right }}
          title={control.label}
          aria-label={control.label}
          disabled={cancellingOrder}
          onPointerDown={(event) => event.stopPropagation()}
          onClick={() => onCancelPendingOrder(control.orderId)}
        >×</button>)}
      </div>
      {openingRangeOverlay && <svg className="paper-opening-range-overlay" viewBox={`0 0 ${openingRangeOverlay.width} ${openingRangeOverlay.height}`} aria-hidden="true">
        {showOpeningRange && <g className="paper-or-range"><rect className="paper-or-box" x={openingRangeOverlay.rangeLeft} y={openingRangeOverlay.highY} width={Math.max(0, openingRangeOverlay.rangeRight - openingRangeOverlay.rangeLeft)} height={Math.max(0, openingRangeOverlay.lowY - openingRangeOverlay.highY)} /><line className="paper-or-boundary" x1={openingRangeOverlay.rangeLeft} x2={openingRangeOverlay.projectionRight} y1={openingRangeOverlay.highY} y2={openingRangeOverlay.highY} /><line className="paper-or-boundary" x1={openingRangeOverlay.rangeLeft} x2={openingRangeOverlay.projectionRight} y1={openingRangeOverlay.lowY} y2={openingRangeOverlay.lowY} /><text className="paper-or-label" x={(openingRangeOverlay.rangeLeft + openingRangeOverlay.rangeRight) / 2} y={openingRangeOverlay.highY + 15}>区间振幅 {formatNumber(openingRangeOverlay.trueRange, 2)}</text><text className="paper-or-price-label" x={openingRangeOverlay.rangeRight - 5} y={openingRangeOverlay.highY - 5}>{formatNumber(openingRangeOverlay.high, 2)}</text><text className="paper-or-price-label" x={openingRangeOverlay.rangeRight - 5} y={openingRangeOverlay.lowY - 5}>{formatNumber(openingRangeOverlay.low, 2)}</text></g>}
        {openingRangeOverlay.completed && showUpperOpeningRange && openingRangeOverlay.trueRange > 0 && <g className="paper-or-upper">
          <rect x={openingRangeOverlay.rangeRight} y={openingRangeOverlay.upperTwoY} width={Math.max(0, openingRangeOverlay.projectionRight - openingRangeOverlay.rangeRight)} height={Math.max(0, openingRangeOverlay.highY - openingRangeOverlay.upperTwoY)} />
          <line x1={openingRangeOverlay.rangeRight} x2={openingRangeOverlay.projectionRight} y1={openingRangeOverlay.upperOneY} y2={openingRangeOverlay.upperOneY} />
          <line x1={openingRangeOverlay.rangeRight} x2={openingRangeOverlay.projectionRight} y1={openingRangeOverlay.upperTwoY} y2={openingRangeOverlay.upperTwoY} />
          <text x={(openingRangeOverlay.rangeRight + openingRangeOverlay.projectionRight) / 2} y={openingRangeOverlay.upperOneY - 5}>+1×TR {formatNumber(openingRangeOverlay.high + openingRangeOverlay.trueRange, 2)}</text>
          <text x={(openingRangeOverlay.rangeRight + openingRangeOverlay.projectionRight) / 2} y={openingRangeOverlay.upperTwoY - 5}>+2×TR {formatNumber(openingRangeOverlay.high + openingRangeOverlay.trueRange * 2, 2)}</text>
        </g>}
        {openingRangeOverlay.completed && showLowerOpeningRange && openingRangeOverlay.trueRange > 0 && <g className="paper-or-lower">
          <rect x={openingRangeOverlay.rangeRight} y={openingRangeOverlay.lowY} width={Math.max(0, openingRangeOverlay.projectionRight - openingRangeOverlay.rangeRight)} height={Math.max(0, openingRangeOverlay.lowerTwoY - openingRangeOverlay.lowY)} />
          <line x1={openingRangeOverlay.rangeRight} x2={openingRangeOverlay.projectionRight} y1={openingRangeOverlay.lowerOneY} y2={openingRangeOverlay.lowerOneY} />
          <line x1={openingRangeOverlay.rangeRight} x2={openingRangeOverlay.projectionRight} y1={openingRangeOverlay.lowerTwoY} y2={openingRangeOverlay.lowerTwoY} />
          <text x={(openingRangeOverlay.rangeRight + openingRangeOverlay.projectionRight) / 2} y={openingRangeOverlay.lowerOneY - 5}>-1×TR {formatNumber(openingRangeOverlay.low - openingRangeOverlay.trueRange, 2)}</text>
          <text x={(openingRangeOverlay.rangeRight + openingRangeOverlay.projectionRight) / 2} y={openingRangeOverlay.lowerTwoY - 5}>-2×TR {formatNumber(openingRangeOverlay.low - openingRangeOverlay.trueRange * 2, 2)}</text>
        </g>}
      </svg>}
      <div className="paper-time-axis" aria-hidden="true">
        {timeAxisLabels.map((label) => <span key={label.key} style={{ left: label.left }}>{label.text}</span>)}
      </div>
    </div>
  </div>;
}

function paperErrorMessage(value: unknown, fallback: string): string {
  if (typeof value === "object" && value !== null && "detail" in value && typeof value.detail === "string") return value.detail;
  return fallback;
}

async function readPaperResponse<T>(response: Response, fallback: string): Promise<T> {
  const rawBody = await response.text();
  let body: unknown = null;
  if (rawBody) {
    try {
      body = JSON.parse(rawBody) as unknown;
    } catch {
      body = null;
    }
  }
  if (!response.ok) {
    throw new Error(paperErrorMessage(body, `${fallback} (HTTP ${response.status})`));
  }
  if (body === null) throw new Error(`${fallback}：服务返回格式异常`);
  return body as T;
}

async function fetchPaperGet<T>(path: string, fallback: string): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    let response: Response;
    try {
      response = await fetch(path, { cache: "no-store" });
    } catch (reason) {
      lastError = reason;
      if (attempt >= 2) break;
      await new Promise((resolve) => window.setTimeout(resolve, 200 * (attempt + 1)));
      continue;
    }
    if (response.status >= 500 && attempt < 2) {
      await new Promise((resolve) => window.setTimeout(resolve, 200 * (attempt + 1)));
      continue;
    }
    return readPaperResponse<T>(response, fallback);
  }
  throw lastError instanceof Error ? lastError : new Error(fallback);
}

function PaperTraderWorkspace({ onBalanceChange }: { onBalanceChange: (balance: number) => void }) {
  const [metadata, setMetadata] = useState<PaperMetadata | null>(null);
  const [symbol, setSymbol] = useState("BTCUSDT");
  const [intervalSeconds, setIntervalSeconds] = useState(300);
  const [rangeStart, setRangeStart] = useState("");
  const [rangeEnd, setRangeEnd] = useState("");
  const [speedSeconds, setSpeedSeconds] = useState(5);
  const [notional, setNotional] = useState<NumericInput>(100);
  const [notionalUnit, setNotionalUnit] = useState<PaperNotionalUnit>("USDT");
  const [leverage, setLeverage] = useState<NumericInput>(100);
  const [takeProfit, setTakeProfit] = useState<NumericInput>("");
  const [stopLoss, setStopLoss] = useState<NumericInput>("");
  const [positionTab, setPositionTab] = useState<"position" | "orders" | "history">("position");
  const [orderTab, setOrderTab] = useState<"open" | "close">("open");
  const [openOrderType, setOpenOrderType] = useState<"LIMIT" | "MARKET">("MARKET");
  const [openPrice, setOpenPrice] = useState<NumericInput>("");
  const [closeOrderType, setCloseOrderType] = useState<"LIMIT" | "MARKET">("LIMIT");
  const [closePrice, setClosePrice] = useState<NumericInput>("");
  const [closeQuantity, setCloseQuantity] = useState<NumericInput>("");
  const [autoTwoRTakeProfit, setAutoTwoRTakeProfit] = useState(true);
  const [showOpeningRange, setShowOpeningRange] = useState(true);
  const [showUpperOpeningRange, setShowUpperOpeningRange] = useState(false);
  const [showLowerOpeningRange, setShowLowerOpeningRange] = useState(false);
  const [positionAction, setPositionAction] = useState(false);
  const [riskDialogOpen, setRiskDialogOpen] = useState(false);
  const [riskDialogError, setRiskDialogError] = useState<string | null>(null);
  const [riskDialogOffset, setRiskDialogOffset] = useState({ x: 0, y: 0 });
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [replayPresets, setReplayPresets] = useState<PaperReplayPreset[]>([]);
  const [preferencesLoaded, setPreferencesLoaded] = useState(false);
  const [replaySource, setReplaySource] = useState<PaperReplaySource>("CUSTOM");
  const [snapshot, setSnapshot] = useState<PaperSessionSnapshot | null>(null);
  const [candles, setCandles] = useState<PaperChartPoint[]>([]);
  const [playing, setPlaying] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const advancingRef = useRef(false);
  const startingSessionRef = useRef(false);
  const riskDialogDragRef = useRef<{
    pointerId: number;
    offsetX: number;
    offsetY: number;
    width: number;
    height: number;
  } | null>(null);

  useEffect(() => {
    void fetchPaperGet<PaperMetadata>("/api/paper-trader/metadata", "模拟器行情范围加载失败")
      .then((value) => {
        setMetadata(value);
        const coverage = value.ranges.find((item) => item.symbol === "BTCUSDT");
        if (coverage?.available_to) {
          const end = new Date(coverage.available_to);
          const earliest = coverage.available_from ? new Date(coverage.available_from).getTime() : 0;
          const start = new Date(Math.max(earliest, end.getTime() - 24 * 60 * 60 * 1000));
          setRangeStart((current) => current || toUtc8Input(start.toISOString()));
          setRangeEnd((current) => current || toUtc8Input(end.toISOString()));
        }
      })
      .catch((reason: unknown) => setError(reason instanceof Error ? reason.message : "模拟器行情范围加载失败"));
  }, []);

  useEffect(() => {
    void fetchPaperGet<PaperTraderPreferences>("/api/account/preferences/paper-trader", "交易偏好读取失败")
      .then((preferences) => {
        setSymbol(preferences.symbol);
        setIntervalSeconds(preferences.interval_seconds);
        if (preferences.range_start) setRangeStart(toUtc8Input(preferences.range_start));
        if (preferences.range_end) setRangeEnd(toUtc8Input(preferences.range_end));
        setSpeedSeconds(preferences.speed_seconds);
        setNotional(preferences.notional);
        setNotionalUnit(preferences.notional_unit);
        setLeverage(preferences.leverage);
        setOpenOrderType(preferences.open_order_type);
        setCloseOrderType(preferences.close_order_type);
        setAutoTwoRTakeProfit(preferences.auto_two_r_take_profit);
        setShowOpeningRange(preferences.show_opening_range);
        setShowUpperOpeningRange(preferences.show_upper_opening_range);
        setShowLowerOpeningRange(preferences.show_lower_opening_range);
        setReplayPresets(preferences.replay_presets.map((preset) => ({
          id: preset.id,
          symbol: preset.symbol,
          intervalSeconds: preset.interval_seconds,
          rangeStart: toUtc8Input(preset.range_start),
          rangeEnd: toUtc8Input(preset.range_end)
        })));
        setPreferencesLoaded(true);
      })
      .catch((reason: unknown) => setError(reason instanceof Error ? reason.message : "交易偏好读取失败"));
  }, []);

  useEffect(() => {
    if (!playing || !snapshot || snapshot.status === "COMPLETED" || snapshot.status === "LIQUIDATED") return;
    const timer = window.setInterval(() => void advance(), speedSeconds * 1000);
    return () => window.clearInterval(timer);
  }, [playing, snapshot?.session_id, snapshot?.status, speedSeconds]);

  useEffect(() => {
    if (snapshot?.status === "COMPLETED" || snapshot?.status === "LIQUIDATED") setPlaying(false);
  }, [snapshot?.status]);

  useEffect(() => {
    if (!preferencesLoaded || notional === "" || leverage === "") return;
    if ((rangeStart === "") !== (rangeEnd === "")) return;
    if (rangeStart && rangeEnd && new Date(utc8InputToIso(rangeStart)) >= new Date(utc8InputToIso(rangeEnd))) return;
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      void fetch("/api/account/preferences/paper-trader", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        signal: controller.signal,
        body: JSON.stringify({
          symbol,
          interval_seconds: intervalSeconds,
          range_start: rangeStart ? utc8InputToIso(rangeStart) : null,
          range_end: rangeEnd ? utc8InputToIso(rangeEnd) : null,
          speed_seconds: speedSeconds,
          notional,
          notional_unit: notionalUnit,
          leverage,
          open_order_type: openOrderType,
          close_order_type: closeOrderType,
          auto_two_r_take_profit: autoTwoRTakeProfit,
          show_opening_range: showOpeningRange,
          show_upper_opening_range: showUpperOpeningRange,
          show_lower_opening_range: showLowerOpeningRange,
          replay_presets: replayPresets.map((preset) => ({
            id: preset.id,
            symbol: preset.symbol,
            interval_seconds: preset.intervalSeconds,
            range_start: utc8InputToIso(preset.rangeStart),
            range_end: utc8InputToIso(preset.rangeEnd)
          }))
        })
      }).then(async (response) => {
        await readPaperResponse<PaperTraderPreferences>(response, "交易偏好保存失败");
      }).catch((reason: unknown) => {
        if (reason instanceof DOMException && reason.name === "AbortError") return;
        setError(reason instanceof Error ? reason.message : "交易偏好保存失败");
      });
    }, 500);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [preferencesLoaded, symbol, intervalSeconds, rangeStart, rangeEnd, speedSeconds, notional, notionalUnit, leverage, openOrderType, closeOrderType, autoTwoRTakeProfit, showOpeningRange, showUpperOpeningRange, showLowerOpeningRange, replayPresets]);

  useEffect(() => {
    setTakeProfit(snapshot?.position?.take_profit_price ?? "");
    setStopLoss(snapshot?.position?.stop_loss_price ?? "");
  }, [snapshot?.position?.take_profit_price, snapshot?.position?.stop_loss_price]);

  useEffect(() => {
    const position = snapshot?.position;
    if (!position) {
      setClosePrice("");
      setCloseQuantity("");
      return;
    }
    setClosePrice(position.take_profit_price ?? position.mark_price);
    setCloseQuantity(position.take_profit_quantity ?? position.quantity);
  }, [snapshot?.position?.quantity, snapshot?.position?.take_profit_price, snapshot?.position?.take_profit_quantity]);

  useEffect(() => {
    if (snapshot && !snapshot.position) setOrderTab("open");
  }, [snapshot?.position]);

  function applySnapshot(next: PaperSessionSnapshot, reset = false) {
    setSnapshot(next);
    onBalanceChange(next.balance);
    setCandles((current) => {
      const point = { ...next.current_candle, ema20: next.ema20, ema240: next.ema240 };
      if (reset) return [point];
      const last = current[current.length - 1];
      return last?.open_time === next.current_candle.open_time ? current : [...current, point];
    });
  }

  async function requestSnapshot(path: string, init?: RequestInit): Promise<PaperSessionSnapshot> {
    const response = await fetch(path, init);
    return readPaperResponse<PaperSessionSnapshot>(response, "模拟交易请求失败");
  }

  async function startGame(
    selectedStart = rangeStart,
    selectedEnd = rangeEnd,
    selectedSymbol = symbol,
    selectedInterval = intervalSeconds,
    selectedSource: PaperReplaySource = "CUSTOM"
  ) {
    if (startingSessionRef.current) return;
    if (!selectedStart || !selectedEnd) {
      setError("请选择完整的行情开始和结束时间");
      return;
    }
    startingSessionRef.current = true;
    setLoading(true);
    setPlaying(false);
    setError(null);
    try {
      const next = await requestSnapshot("/api/paper-trader/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ symbol: selectedSymbol, interval_seconds: selectedInterval, range_start: utc8InputToIso(selectedStart), range_end: utc8InputToIso(selectedEnd) })
      });
      applySnapshot(next, true);
      setOrderTab("open");
      setOpenPrice(next.current_candle.close_price);
      setRiskDialogOpen(false);
      setSettingsOpen(false);
      setReplaySource(selectedSource);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "模拟账户创建失败");
    } finally {
      startingSessionRef.current = false;
      setLoading(false);
    }
  }

  function startRandomSession(kind: "US" | "ASIA") {
    if (startingSessionRef.current) return;
    const coverage = metadata?.ranges.find((item) => item.symbol === symbol);
    if (!coverage?.available_from || !coverage.available_to) {
      setError(`${symbol} 暂无可用的本地历史行情`);
      return;
    }
    const selected = kind === "US"
      ? randomTradingSession(coverage.available_from, coverage.available_to, 21, 30, 7, true)
      : randomTradingSession(coverage.available_from, coverage.available_to, 8, 0, 10, false);
    if (!selected) {
      setError(kind === "US"
        ? "本地行情范围内没有完整的工作日美盘早盘（UTC+8 21:30—次日 04:30）"
        : "本地行情范围内没有完整的亚洲时段（UTC+8 08:00—18:00）");
      return;
    }
    setRangeStart(selected.rangeStart);
    setRangeEnd(selected.rangeEnd);
    void startGame(selected.rangeStart, selected.rangeEnd, symbol, intervalSeconds, kind);
  }

  function restartCurrentRound() {
    if (!snapshot) return;
    const selectedStart = toUtc8Input(snapshot.range_start);
    const selectedEnd = toUtc8Input(snapshot.range_end);
    setSymbol(snapshot.symbol);
    setIntervalSeconds(snapshot.interval_seconds);
    setRangeStart(selectedStart);
    setRangeEnd(selectedEnd);
    void startGame(
      selectedStart,
      selectedEnd,
      snapshot.symbol,
      snapshot.interval_seconds,
      replaySource
    );
  }

  function startRandomNextRound() {
    startRandomSession(replaySource === "ASIA" ? "ASIA" : "US");
  }

  function selectReplaySymbol(nextSymbol: string) {
    setSymbol(nextSymbol);
    const coverage = metadata?.ranges.find((item) => item.symbol === nextSymbol);
    if (!coverage?.available_to) return;
    const end = new Date(coverage.available_to);
    const earliest = coverage.available_from ? new Date(coverage.available_from).getTime() : 0;
    const start = new Date(Math.max(earliest, end.getTime() - 24 * 60 * 60 * 1000));
    setRangeStart(toUtc8Input(start.toISOString()));
    setRangeEnd(toUtc8Input(end.toISOString()));
  }

  function saveReplayPreset() {
    if (!rangeStart || !rangeEnd) {
      setError("请选择完整的行情开始和结束时间");
      return;
    }
    if (new Date(utc8InputToIso(rangeStart)) >= new Date(utc8InputToIso(rangeEnd))) {
      setError("行情开始时间必须早于结束时间");
      return;
    }
    const duplicate = replayPresets.find((preset) => preset.symbol === symbol && preset.intervalSeconds === intervalSeconds && preset.rangeStart === rangeStart && preset.rangeEnd === rangeEnd);
    if (duplicate) {
      setError("该自定义行情已经保存为快捷配置");
      return;
    }
    setReplayPresets((current) => [...current, {
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      symbol,
      intervalSeconds,
      rangeStart,
      rangeEnd
    }]);
    setError(null);
    setSettingsOpen(false);
  }

  function startReplayPreset(preset: PaperReplayPreset) {
    if (startingSessionRef.current) return;
    setSymbol(preset.symbol);
    setIntervalSeconds(preset.intervalSeconds);
    setRangeStart(preset.rangeStart);
    setRangeEnd(preset.rangeEnd);
    void startGame(preset.rangeStart, preset.rangeEnd, preset.symbol, preset.intervalSeconds);
  }

  function removeReplayPreset(id: string) {
    setReplayPresets((current) => current.filter((preset) => preset.id !== id));
  }

  async function advance() {
    if (!snapshot || advancingRef.current) return;
    advancingRef.current = true;
    setError(null);
    try {
      const next = await requestSnapshot(`/api/paper-trader/sessions/${snapshot.session_id}/advance`, { method: "POST" });
      const limitOrderFilled = !snapshot.position && !!next.position;
      applySnapshot(next);
      if (limitOrderFilled) setOrderTab("close");
    } catch (reason) {
      setPlaying(false);
      setError(reason instanceof Error ? reason.message : "K 线推进失败");
    } finally {
      advancingRef.current = false;
    }
  }

  async function openPosition(side: PaperSide) {
    if (!snapshot) return;
    if (notional === "" || leverage === "") {
      setError("请填写名义下单价值和杠杆倍数");
      return;
    }
    if (openOrderType === "LIMIT" && (openPrice === "" || !Number.isFinite(openPrice) || openPrice <= 0)) {
      setError("请填写有效的开仓限价");
      return;
    }
    setError(null);
    try {
      applySnapshot(await requestSnapshot(`/api/paper-trader/sessions/${snapshot.session_id}/orders`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          side,
          notional,
          notional_unit: notionalUnit,
          leverage,
          order_type: openOrderType,
          price: openOrderType === "LIMIT" ? openPrice : null
        })
      }));
      if (openOrderType === "MARKET") setOrderTab("close");
      else setPositionTab("orders");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "下单失败");
    }
  }

  async function cancelPendingOrder(orderId: string) {
    if (!snapshot) return;
    setPositionAction(true);
    setError(null);
    try {
      applySnapshot(await requestSnapshot(`/api/paper-trader/sessions/${snapshot.session_id}/orders/${orderId}`, {
        method: "DELETE"
      }));
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "撤销委托失败");
    } finally {
      setPositionAction(false);
    }
  }

  async function closePosition(quantity?: number) {
    if (!snapshot) return;
    setPositionAction(true);
    setError(null);
    try {
      const next = await requestSnapshot(`/api/paper-trader/sessions/${snapshot.session_id}/close`, {
        method: "POST",
        headers: quantity === undefined ? undefined : { "Content-Type": "application/json" },
        body: quantity === undefined ? undefined : JSON.stringify({ quantity })
      });
      applySnapshot(next);
      if (!next.position) {
        setOrderTab("open");
      } else {
        setClosePrice(next.position.mark_price);
        setCloseQuantity(next.position.quantity);
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "平仓失败");
    } finally {
      setPositionAction(false);
    }
  }

  async function saveRiskOrders() {
    if (!snapshot?.position) return;
    setPositionAction(true);
    setError(null);
    setRiskDialogError(null);
    try {
      applySnapshot(await requestSnapshot(`/api/paper-trader/sessions/${snapshot.session_id}/risk`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          take_profit_price: takeProfit === "" ? null : takeProfit,
          take_profit_quantity: takeProfit === "" ? null : snapshot.position.quantity,
          stop_loss_price: stopLoss === "" ? null : stopLoss
        })
      }));
      setPositionTab("orders");
      setRiskDialogOpen(false);
    } catch (reason) {
      setRiskDialogError(reason instanceof Error ? reason.message : "止盈止损设置失败");
    } finally {
      setPositionAction(false);
    }
  }

  function openRiskDialog() {
    if (!snapshot?.position) return;
    setPlaying(false);
    setRiskDialogError(null);
    const savedStopLoss = snapshot.position.stop_loss_price ?? "";
    setStopLoss(savedStopLoss);
    setTakeProfit(snapshot.position.take_profit_price ?? calculateTwoRTakeProfit(savedStopLoss));
    setRiskDialogOffset({ x: 0, y: 0 });
    setRiskDialogOpen(true);
  }

  function startRiskDialogDrag(event: React.PointerEvent<HTMLElement>) {
    if (event.button !== 0 || (event.target as HTMLElement).closest("button")) return;
    const dialog = event.currentTarget.closest<HTMLElement>(".paper-risk-dialog");
    if (!dialog) return;
    const bounds = dialog.getBoundingClientRect();
    riskDialogDragRef.current = {
      pointerId: event.pointerId,
      offsetX: event.clientX - bounds.left,
      offsetY: event.clientY - bounds.top,
      width: bounds.width,
      height: bounds.height
    };
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function moveRiskDialog(event: React.PointerEvent<HTMLElement>) {
    const drag = riskDialogDragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    const margin = 8;
    const maxLeft = Math.max(margin, window.innerWidth - drag.width - margin);
    const maxTop = Math.max(margin, window.innerHeight - drag.height - margin);
    const left = Math.min(maxLeft, Math.max(margin, event.clientX - drag.offsetX));
    const top = Math.min(maxTop, Math.max(margin, event.clientY - drag.offsetY));
    const centeredLeft = (window.innerWidth - drag.width) / 2;
    const centeredTop = (window.innerHeight - drag.height) / 2;
    setRiskDialogOffset({ x: left - centeredLeft, y: top - centeredTop });
  }

  function stopRiskDialogDrag(event: React.PointerEvent<HTMLElement>) {
    const drag = riskDialogDragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    riskDialogDragRef.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  }

  function calculateTwoRTakeProfit(stopLossPrice: NumericInput): NumericInput {
    const position = snapshot?.position;
    if (!position || stopLossPrice === "") return "";
    const risk = position.side === "LONG"
      ? position.entry_price - stopLossPrice
      : stopLossPrice - position.entry_price;
    if (risk <= 0) return "";
    const target = position.side === "LONG"
      ? position.entry_price + risk * 2
      : position.entry_price - risk * 2;
    return Number(target.toFixed(8));
  }

  function updateStopLoss(value: string) {
    setRiskDialogError(null);
    const nextStopLoss: NumericInput = value === "" ? "" : Number(value);
    setStopLoss(nextStopLoss);
    if (autoTwoRTakeProfit) setTakeProfit(calculateTwoRTakeProfit(nextStopLoss));
  }

  function toggleAutoTwoRTakeProfit() {
    const enabled = !autoTwoRTakeProfit;
    setAutoTwoRTakeProfit(enabled);
    if (enabled) setTakeProfit(calculateTwoRTakeProfit(stopLoss));
  }

  function applyNotionalPercentage(percentage: number) {
    if (maximumNotional === undefined || maximumNotional <= 0) return;
    const precision = notionalUnit === "USDT" ? 2 : 6;
    setNotional(Number((maximumNotional * percentage).toFixed(precision)));
  }

  function openCloseOrderTab() {
    setOrderTab("close");
    const position = snapshot?.position;
    if (!position) return;
    setClosePrice(position.take_profit_price ?? position.mark_price);
    setCloseQuantity(position.take_profit_quantity ?? position.quantity);
  }

  function applyClosePercentage(percentage: number) {
    const quantity = snapshot?.position?.quantity;
    if (!quantity) return;
    setCloseQuantity(Number((quantity * percentage).toFixed(8)));
  }

  async function submitCloseOrder() {
    const position = snapshot?.position;
    if (!snapshot || !position || closeQuantity === "") return;
    if (!Number.isFinite(closeQuantity) || closeQuantity <= 0 || closeQuantity > position.quantity + 1e-12) {
      setError("平仓数量必须大于 0，且不能超过当前持仓数量");
      return;
    }
    if (closeOrderType === "MARKET") {
      await closePosition(closeQuantity);
      return;
    }
    if (closePrice === "" || !Number.isFinite(closePrice) || closePrice <= 0) {
      setError("请填写有效的止盈价格");
      return;
    }
    setPositionAction(true);
    setError(null);
    try {
      const next = await requestSnapshot(`/api/paper-trader/sessions/${snapshot.session_id}/close`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          quantity: closeQuantity,
          order_type: "LIMIT",
          price: closePrice
        })
      });
      applySnapshot(next);
      setTakeProfit(next.position?.take_profit_price ?? "");
      if (next.position) {
        setClosePrice(next.position.take_profit_price ?? next.position.mark_price);
        setCloseQuantity(next.position.take_profit_quantity ?? next.position.quantity);
        setPositionTab(next.pending_orders.some((order) => order.order_kind === "CLOSE" && order.order_type === "LIMIT") ? "orders" : "position");
      } else {
        setOrderTab("open");
        setPositionTab("history");
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "止盈委托提交失败");
    } finally {
      setPositionAction(false);
    }
  }

  const gameEnded = snapshot?.status === "COMPLETED" || snapshot?.status === "LIQUIDATED";
  const anchoredChangeClass = snapshot?.anchored_price_change === null || (snapshot?.anchored_price_change ?? 0) >= 0 ? "candle-change-up" : "candle-change-down";
  const pnl = snapshot?.position?.unrealized_pnl ?? 0;
  const baseAsset = (snapshot?.symbol ?? symbol).replace("USDT", "");
  const orderPrice = snapshot?.current_candle.close_price ?? 0;
  const entryTargetPrice = openOrderType === "LIMIT" && openPrice !== "" ? openPrice : orderPrice;
  const hasPendingOpenOrder = snapshot?.pending_orders.some((order) => order.order_kind === "OPEN") ?? false;
  const numericNotional = notional === "" ? null : notional;
  const numericLeverage = leverage === "" ? null : leverage;
  const notionalUsdt = numericNotional === null
    ? null
    : notionalUnit === "USDT" ? numericNotional : numericNotional * entryTargetPrice;
  const estimatedMargin = notionalUsdt !== null && numericLeverage !== null && numericLeverage > 0
    ? notionalUsdt / numericLeverage
    : null;
  const maximumNotional = snapshot && entryTargetPrice > 0 && numericLeverage !== null
    ? notionalUnit === "USDT"
      ? snapshot.available_balance * numericLeverage
      : snapshot.available_balance * numericLeverage / entryTargetPrice
    : undefined;
  const invalidOrder = numericNotional === null || !Number.isFinite(numericNotional) || numericNotional <= 0 ||
    numericLeverage === null || !Number.isInteger(numericLeverage) || numericLeverage < 1 || numericLeverage > 100 ||
    estimatedMargin === null || !Number.isFinite(estimatedMargin) || estimatedMargin > (snapshot?.available_balance ?? 0);
  const invalidLongLimit = openOrderType === "LIMIT" && (openPrice === "" || openPrice >= orderPrice);
  const invalidShortLimit = openOrderType === "LIMIT" && (openPrice === "" || openPrice <= orderPrice);
  const maintenanceMarginRate = metadata?.maintenance_margin_rate ?? 0.005;
  const estimatedQuantity = notionalUsdt !== null && notionalUsdt > 0 && entryTargetPrice > 0
    ? notionalUsdt / entryTargetPrice
    : null;
  const estimatedLongLiquidation = snapshot && estimatedQuantity !== null
    ? Math.max(0, (entryTargetPrice - snapshot.balance / estimatedQuantity) / (1 - maintenanceMarginRate))
    : null;
  const estimatedShortLiquidation = snapshot && estimatedQuantity !== null
    ? (entryTargetPrice + snapshot.balance / estimatedQuantity) / (1 + maintenanceMarginRate)
    : null;
  const maximumBaseQuantity = snapshot && numericLeverage !== null && entryTargetPrice > 0
    ? snapshot.available_balance * numericLeverage / entryTargetPrice
    : null;
  const positionNotional = snapshot?.position
    ? snapshot.position.quantity * snapshot.position.mark_price
    : 0;
  const actualLeverage = snapshot && snapshot.equity > 0 ? positionNotional / snapshot.equity : 0;
  const maintenanceMargin = positionNotional * maintenanceMarginRate;
  const projectedPnl = (target: NumericInput) => {
    if (!snapshot?.position || target === "" || target <= 0) return null;
    const movement = snapshot.position.side === "LONG"
      ? target - snapshot.position.entry_price
      : snapshot.position.entry_price - target;
    return movement * snapshot.position.quantity;
  };
  const projectedTakeProfit = projectedPnl(takeProfit);
  const projectedStopLoss = projectedPnl(stopLoss);
  const numericCloseQuantity = closeQuantity === "" ? null : closeQuantity;
  const requestedClosePrice = closeOrderType === "MARKET" ? orderPrice : closePrice === "" ? null : closePrice;
  const closeTargetPrice = snapshot?.position && requestedClosePrice !== null && closeOrderType === "LIMIT" && (
    (snapshot.position.side === "LONG" && requestedClosePrice <= orderPrice)
    || (snapshot.position.side === "SHORT" && requestedClosePrice >= orderPrice)
  ) ? orderPrice : requestedClosePrice;
  const projectedClosePnl = snapshot?.position && numericCloseQuantity !== null && closeTargetPrice !== null
    ? (snapshot.position.side === "LONG" ? closeTargetPrice - snapshot.position.entry_price : snapshot.position.entry_price - closeTargetPrice) * numericCloseQuantity
    : null;
  const invalidCloseOrder = !snapshot?.position || numericCloseQuantity === null || !Number.isFinite(numericCloseQuantity) || numericCloseQuantity <= 0 || numericCloseQuantity > snapshot.position.quantity + 1e-12 || closeTargetPrice === null || !Number.isFinite(closeTargetPrice) || closeTargetPrice <= 0;
  return <main className="paper-page">
    <header className="topbar">
      <div><p className="brand-mark">PAPER TRADER</p><h1>交易模拟器</h1><p className="subtitle">使用自定义配置或随机交易时段生成历史行情，逐根回放 K 线，在个人模拟账户中练习仓位与杠杆。</p></div>
      <div className="paper-page-actions">
        <div className="paper-rule-badge"><span>首版撮合规则</span><strong>市价成交 · 单持仓 · 全仓模式 · 维持保证金率 0.5%</strong></div>
        <div><button type="button" onClick={() => setSettingsOpen((value) => !value)} aria-expanded={settingsOpen}>{settingsOpen ? "收起自定义" : "⚙ 自定义行情"}</button></div>
      </div>
    </header>
    <section className="paper-session-shortcuts" aria-label="行情生成快捷入口">
      <span>行情生成</span>
      <button className="paper-session-random" type="button" onClick={() => startRandomSession("US")} disabled={loading || !metadata || !!snapshot?.position}>{loading ? "正在载入…" : "随机美盘 · 21:30—04:30"}</button>
      <button className="paper-session-random" type="button" onClick={() => startRandomSession("ASIA")} disabled={loading || !metadata || !!snapshot?.position}>{loading ? "正在载入…" : "随机亚洲 · 08:00—18:00"}</button>
      {replayPresets.map((preset) => <div className="paper-saved-preset" key={preset.id}><button type="button" onClick={() => startReplayPreset(preset)} disabled={loading || !!snapshot?.position}>{paperReplayPresetLabel(preset)}</button><button type="button" onClick={() => removeReplayPreset(preset.id)} disabled={loading || !!snapshot?.position} aria-label={`删除 ${paperReplayPresetLabel(preset)}`}>×</button></div>)}
    </section>
    {settingsOpen && <section className="panel paper-config">
      <div className="paper-config-heading"><strong>自定义行情</strong><span>设置交易对、K 线级别和时间范围，可直接开始或保存为快捷按钮。</span></div>
      <div className="paper-config-grid">
        <label><span>交易对</span><select value={symbol} onChange={(event) => selectReplaySymbol(event.target.value)} disabled={!!snapshot?.position}><option>BTCUSDT</option><option>ETHUSDT</option></select></label>
        <label><span>K 线级别</span><select value={intervalSeconds} onChange={(event) => setIntervalSeconds(Number(event.target.value))} disabled={!!snapshot?.position}><option value={300}>5min</option><option value={900}>15min</option><option value={3600}>1h</option></select></label>
        <label><span>开始时间 UTC+8</span><input type="datetime-local" value={rangeStart} onChange={(event) => setRangeStart(event.target.value)} disabled={!!snapshot?.position} /></label>
        <label><span>结束时间 UTC+8</span><input type="datetime-local" value={rangeEnd} onChange={(event) => setRangeEnd(event.target.value)} disabled={!!snapshot?.position} /></label>
        <div className="paper-start-actions">
          <button type="button" onClick={saveReplayPreset} disabled={loading || !metadata || !!snapshot?.position}>保存快捷配置</button>
          <button className="primary-button" type="button" onClick={() => void startGame()} disabled={loading || !metadata || !!snapshot?.position}>{loading ? "正在载入…" : "生成行情"}</button>
        </div>
      </div>
      <p className="paper-random-hint">随机美盘仅抽取周一至周五；随机亚洲时段可从本地完整历史日期中抽取。</p>
    </section>}
    {error && <div className="alert alert-critical">{error}</div>}
    {snapshot?.message?.startsWith("价格触及止损价") && snapshot.trades[snapshot.trades.length - 1]?.exit_reason === "STOP_LOSS" && <div className="alert paper-stop-loss-notice">{snapshot.message}</div>}
    {!snapshot ? <section className="panel paper-empty"><strong>准备开始</strong><p>载入后只会显示第一根 K 线，后续行情不会提前暴露。</p></section> : <>
      <section className="paper-workspace">
        <div className="paper-main-column">
          <div className="panel paper-chart-panel">
            <div className="paper-playback-bar">
              <div><strong>{snapshot.symbol} · {snapshot.interval_seconds / 60}{snapshot.interval_seconds < 3600 ? "min" : "h"}</strong><span>{snapshot.revealed_count} / {snapshot.total_candles} 根</span><span className="paper-playback-change" title="以当前 UTC+8 交易日 08:00 K 线开盘价为基准"><em>Chg</em>{snapshot.anchored_price_change === null || snapshot.anchored_price_change_percent === null ? <strong>--</strong> : <><strong className={anchoredChangeClass}>{snapshot.anchored_price_change_percent >= 0 ? "+" : ""}{snapshot.anchored_price_change_percent.toFixed(2)}%</strong><strong className={anchoredChangeClass}>{snapshot.anchored_price_change >= 0 ? "+" : ""}{formatNumber(snapshot.anchored_price_change, 2)}</strong></>}</span></div>
              <div className="paper-playback-actions">
                <div className="paper-opening-range-toggles" aria-label="美股早盘区间显示设置" title="UTC+8 21:30–23:00 开盘区间">
                  <label className="paper-range-toggle"><input type="checkbox" checked={showOpeningRange} onChange={(event) => setShowOpeningRange(event.target.checked)} /><span aria-hidden="true" /><strong>区间框</strong></label>
                  <label className="paper-range-toggle"><input type="checkbox" checked={showUpperOpeningRange} onChange={(event) => setShowUpperOpeningRange(event.target.checked)} /><span aria-hidden="true" /><strong>上方 TR</strong></label>
                  <label className="paper-range-toggle"><input type="checkbox" checked={showLowerOpeningRange} onChange={(event) => setShowLowerOpeningRange(event.target.checked)} /><span aria-hidden="true" /><strong>下方 TR</strong></label>
                </div>
                <label><span>回放速度</span><select value={speedSeconds} onChange={(event) => setSpeedSeconds(Number(event.target.value))}><option value={1}>每 1 秒一根</option><option value={3}>每 3 秒一根</option><option value={5}>每 5 秒一根</option><option value={10}>每 10 秒一根</option><option value={15}>每 15 秒一根</option><option value={30}>每 30 秒一根</option></select></label><button type="button" onClick={() => setPlaying((value) => !value)} disabled={gameEnded}>{playing ? "暂停" : "播放"}</button><button type="button" onClick={() => void advance()} disabled={playing || gameEnded}>下一根</button></div>
            </div>
            <div className="paper-chart-stage">
              <PaperReplayChart candles={candles} position={snapshot.position} pendingOrders={snapshot.pending_orders} intervalSeconds={snapshot.interval_seconds} sessionId={snapshot.session_id} showOpeningRange={showOpeningRange} showUpperOpeningRange={showUpperOpeningRange} showLowerOpeningRange={showLowerOpeningRange} onCancelPendingOrder={(orderId) => void cancelPendingOrder(orderId)} cancellingOrder={positionAction} />
              {gameEnded && <section className={`paper-game-over ${snapshot.status === "LIQUIDATED" ? "liquidated" : ""}`}><p>{snapshot.status === "LIQUIDATED" ? "LIQUIDATED" : "REPLAY COMPLETE"}</p><h2>{snapshot.message}</h2><strong>最终余额 {formatNumber(snapshot.balance, 2)} USDT</strong><div className="paper-game-over-actions"><button type="button" onClick={restartCurrentRound} disabled={loading}>{loading ? "正在载入…" : "重来一轮"}</button><button className="primary-button" type="button" onClick={startRandomNextRound} disabled={loading || !metadata}>{loading ? "正在载入…" : "随机下一轮"}</button></div></section>}
            </div>
          </div>
          <section className="panel paper-position-manager">
            <div className="paper-position-tabs"><button type="button" className={positionTab === "position" ? "active" : ""} onClick={() => setPositionTab("position")}>当前持仓</button><button type="button" className={positionTab === "orders" ? "active" : ""} onClick={() => setPositionTab("orders")}>当前委托 <span>{snapshot.pending_orders.length}</span></button><button type="button" className={positionTab === "history" ? "active" : ""} onClick={() => setPositionTab("history")}>历史订单 <span>{snapshot.trades.length}</span></button><label className="paper-two-r-toggle"><input type="checkbox" checked={autoTwoRTakeProfit} onChange={toggleAutoTwoRTakeProfit} /><span aria-hidden="true" /><strong>自动 2R 止盈</strong></label></div>
            {positionTab === "position" ? snapshot.position ? <div className="paper-position-table-wrap">
              <table className="paper-position-table">
                <thead><tr><th>合约</th><th>方向</th><th>状态</th><th>数量 ({baseAsset})</th><th>开仓均价</th><th>持仓方式</th><th>强平价</th><th>未实现盈亏</th><th>保证金</th><th>止盈 / 止损</th><th>操作</th></tr></thead>
                <tbody><tr>
                  <td><strong>{snapshot.symbol}</strong></td>
                  <td className={snapshot.position.side === "LONG" ? "paper-long-price" : "paper-short-price"}>{snapshot.position.side === "LONG" ? "多" : "空"}</td>
                  <td><span className="paper-position-status">开仓</span></td>
                  <td>{formatNumber(snapshot.position.quantity, 6)}</td>
                  <td>{formatNumber(snapshot.position.entry_price, 2)}</td>
                  <td>全仓 · {snapshot.position.leverage}x</td>
                  <td className="paper-danger">{snapshot.position.liquidation_price <= 0 ? "--" : formatNumber(snapshot.position.liquidation_price, 2)}</td>
                  <td className={pnl >= 0 ? "paper-long-price" : "paper-short-price"}>{pnl >= 0 ? "+" : ""}{formatNumber(pnl, 2)}<small>{snapshot.position.return_on_margin_percent >= 0 ? "+" : ""}{snapshot.position.return_on_margin_percent.toFixed(2)}%</small></td>
                  <td>{formatNumber(snapshot.position.margin, 2)} USDT</td>
                  <td><div className="paper-position-risk-summary"><span>{snapshot.position.take_profit_price === null ? "--" : formatNumber(snapshot.position.take_profit_price, 2)} / {snapshot.position.stop_loss_price === null ? "--" : formatNumber(snapshot.position.stop_loss_price, 2)}</span><button type="button" onClick={openRiskDialog} disabled={positionAction} aria-label="设置止盈止损">设置</button></div></td>
                  <td><button type="button" className="paper-market-close" onClick={() => void closePosition()} disabled={positionAction}>市价平仓</button></td>
                </tr></tbody>
              </table>
            </div> : <div className="paper-position-empty">当前没有持仓，可在右侧下单面板开多或开空。</div> : positionTab === "orders" ? snapshot.pending_orders.length ? <div className="paper-position-table-wrap"><table className="paper-position-table paper-orders-table"><thead><tr><th>合约</th><th>委托方向</th><th>委托类型</th><th>价格</th><th>数量 ({baseAsset})</th><th>杠杆</th><th>提交时间</th><th>状态</th><th>操作</th></tr></thead><tbody>{snapshot.pending_orders.map((order) => <tr key={order.order_id}><td><strong>{snapshot.symbol}</strong></td><td className={order.position_side === "LONG" ? "paper-long-price" : "paper-short-price"}>{order.order_kind === "OPEN" ? "开" : "平"}{order.position_side === "LONG" ? "多" : "空"}</td><td>{order.order_type === "LIMIT" ? order.order_kind === "CLOSE" ? "限价止盈" : "限价" : "止损"}</td><td>{formatNumber(order.price, 2)}</td><td>{formatNumber(order.quantity, 6)}</td><td>{order.leverage}x</td><td>{formatKlineTime(order.created_at)}</td><td><span className="paper-order-active">委托中</span></td><td><button type="button" className="paper-cancel-order" onClick={() => void cancelPendingOrder(order.order_id)} disabled={positionAction}>撤单</button></td></tr>)}</tbody></table></div> : <div className="paper-position-empty">当前没有未成交委托。</div> : snapshot.trades.length ? <div className="paper-position-table-wrap"><table className="paper-position-table paper-history-table"><thead><tr><th>平仓时间</th><th>方向</th><th>数量</th><th>开仓价</th><th>平仓价</th><th>杠杆</th><th>已实现盈亏</th><th>原因</th></tr></thead><tbody>{snapshot.trades.slice().reverse().map((trade) => <tr key={`${trade.opened_at}-${trade.closed_at}`}><td>{formatKlineTime(trade.closed_at)}</td><td className={trade.side === "LONG" ? "paper-long-price" : "paper-short-price"}>{trade.side === "LONG" ? "多" : "空"}</td><td>{formatNumber(trade.quantity, 6)} {baseAsset}</td><td>{formatNumber(trade.entry_price, 2)}</td><td>{formatNumber(trade.exit_price, 2)}</td><td>{trade.leverage}x</td><td className={profitClass(trade.realized_pnl)}>{trade.realized_pnl >= 0 ? "+" : ""}{formatNumber(trade.realized_pnl, 2)}</td><td>{trade.exit_reason}</td></tr>)}</tbody></table></div> : <div className="paper-position-empty">本轮暂无历史订单。</div>}
          </section>
        </div>
        <aside className="panel paper-order-panel">
          <div className="paper-order-tabs" role="tablist" aria-label="下单操作"><button type="button" role="tab" aria-selected={orderTab === "open"} className={orderTab === "open" ? "active" : ""} onClick={() => setOrderTab("open")}>开仓</button><button type="button" role="tab" aria-selected={orderTab === "close"} className={orderTab === "close" ? "active" : ""} onClick={openCloseOrderTab}>平仓</button></div>
          {orderTab === "open" ? <div className="paper-order-form">
              <div className="paper-close-type-tabs" role="tablist" aria-label="开仓类型">
                <button type="button" className={openOrderType === "LIMIT" ? "active" : ""} onClick={() => { setOpenOrderType("LIMIT"); if (openPrice === "") setOpenPrice(orderPrice); }}>限价</button>
                <button type="button" className={openOrderType === "MARKET" ? "active" : ""} onClick={() => setOpenOrderType("MARKET")}>市价</button>
              </div>
              {openOrderType === "MARKET" ? <div className="paper-market-price"><span>成交价格</span><strong>{formatNumber(orderPrice, 2)}</strong><em>USDT</em></div> : <label><span>价格</span><div className="paper-close-input"><input type="number" min="0" step="0.01" value={openPrice} onChange={(event) => setOpenPrice(event.target.value === "" ? "" : Number(event.target.value))} disabled={gameEnded || !!snapshot.position || hasPendingOpenOrder} /><em>USDT</em></div></label>}
              <label><span>名义下单价值</span><div className="paper-notional-input"><input type="number" min={notionalUnit === "USDT" ? 1 : 0.000001} max={maximumNotional} step={notionalUnit === "USDT" ? 10 : 0.001} value={notional} onChange={(event) => setNotional(event.target.value === "" ? "" : Number(event.target.value))} disabled={gameEnded || !!snapshot.position || hasPendingOpenOrder} /><select value={notionalUnit} onChange={(event) => setNotionalUnit(event.target.value as PaperNotionalUnit)} disabled={gameEnded || !!snapshot.position || hasPendingOpenOrder}><option value="USDT">USDT</option><option value="BASE">{baseAsset}</option></select></div></label>
              <label className="paper-leverage-field"><span>杠杆</span><select value={leverage} onChange={(event) => setLeverage(Number(event.target.value))} disabled={gameEnded || !!snapshot.position || hasPendingOpenOrder} aria-label="杠杆倍数">{[1, 2, 3, 5, 10, 20, 25, 50, 75, 100].map((value) => <option key={value} value={value}>{value}x</option>)}</select></label>
              <div className="paper-order-percentages" aria-label="按可用余额选择名义价值">{[.25, .5, .75, 1].map((percentage) => <button key={percentage} type="button" onClick={() => applyNotionalPercentage(percentage)} disabled={gameEnded || !!snapshot.position || hasPendingOpenOrder || maximumNotional === undefined}>{percentage * 100}%</button>)}</div>
              <p className="paper-order-warning">名义价值按可用余额和杠杆估算，实际下单前仍会校验保证金。</p>
              <div className="paper-order-estimates">
                <div><span>预计保证金{numericLeverage === null ? "" : `（${numericLeverage}x）`}</span><strong>{estimatedMargin === null ? "—" : `${formatNumber(estimatedMargin, 2)} USDT`}</strong></div>
                <div className="paper-liquidation-estimate"><span>预计全仓强平价</span><dl><div><dt>开多</dt><dd className="paper-long-price">{estimatedLongLiquidation === null || estimatedLongLiquidation <= 0 ? "—" : formatNumber(estimatedLongLiquidation, 2)}</dd></div><div><dt>开空</dt><dd className="paper-short-price">{estimatedShortLiquidation === null ? "—" : formatNumber(estimatedShortLiquidation, 2)}</dd></div></dl></div>
              </div>
              <div className="paper-order-buttons"><button type="button" className="paper-long-button" onClick={() => void openPosition("LONG")} disabled={gameEnded || !!snapshot.position || hasPendingOpenOrder || invalidOrder || invalidLongLimit}>开多</button><button type="button" className="paper-short-button" onClick={() => void openPosition("SHORT")} disabled={gameEnded || !!snapshot.position || hasPendingOpenOrder || invalidOrder || invalidShortLimit}>开空</button></div>
              <div className="paper-order-capacity"><span>最大可开</span><strong>{maximumBaseQuantity === null ? "—" : `${formatNumber(maximumBaseQuantity, 6)} ${baseAsset}`}</strong></div>
              <small>{openOrderType === "MARKET" ? "按当前已揭示 K 线收盘价成交，不收手续费与资金费。" : "限价委托将在后续 K 线触及价格时成交；开多限价需低于当前价，开空限价需高于当前价。"}</small>
            </div> : <div className="paper-close-form">
              {snapshot.position ? <>
                <div className="paper-close-type-tabs" role="tablist" aria-label="平仓类型">
                  <button type="button" className={closeOrderType === "LIMIT" ? "active" : ""} onClick={() => setCloseOrderType("LIMIT")}>限价</button>
                  <button type="button" className={closeOrderType === "MARKET" ? "active" : ""} onClick={() => setCloseOrderType("MARKET")}>市价</button>
                  <button type="button" onClick={openRiskDialog}>条件</button>
                </div>
                <label><span>价格</span><div className="paper-close-input"><input type="number" min="0" step="0.01" value={closeOrderType === "MARKET" ? orderPrice : closePrice} onChange={(event) => setClosePrice(event.target.value === "" ? "" : Number(event.target.value))} disabled={closeOrderType === "MARKET" || positionAction} /><em>USDT</em></div></label>
                <label><span>仓位大小</span><div className="paper-close-input"><input type="number" min="0" max={snapshot.position.quantity} step="0.000001" value={closeQuantity} onChange={(event) => setCloseQuantity(event.target.value === "" ? "" : Number(event.target.value))} disabled={positionAction} /><em>{baseAsset}</em></div></label>
                <div className="paper-order-percentages" aria-label="选择平仓比例">{[.25, .5, .75, 1].map((percentage) => <button key={percentage} type="button" onClick={() => applyClosePercentage(percentage)} disabled={positionAction}>{percentage * 100}%</button>)}</div>
                {closeOrderType === "LIMIT" && <p className="paper-order-warning">提交新的止盈委托时，将先取消当前止盈委托，再以最新价格和数量重新创建。</p>}
                <dl className="paper-close-summary">
                  <div><dt>当前止盈委托</dt><dd>{snapshot.position.take_profit_price === null ? "--" : `${formatNumber(snapshot.position.take_profit_price, 2)} / ${formatNumber(snapshot.position.take_profit_quantity ?? snapshot.position.quantity, 6)} ${baseAsset}`}</dd></div>
                  <div><dt>预计平仓价格</dt><dd>{closeTargetPrice === null ? "--" : `${formatNumber(closeTargetPrice, 2)} USDT`}</dd></div>
                  <div><dt>预计已实现盈亏</dt><dd className={projectedClosePnl === null || projectedClosePnl >= 0 ? "paper-long-price" : "paper-short-price"}>{projectedClosePnl === null ? "--" : `${projectedClosePnl >= 0 ? "+" : ""}${formatNumber(projectedClosePnl, 2)} USDT`}</dd></div>
                </dl>
                <div className="paper-order-buttons"><button type="button" className="paper-long-button" onClick={() => void submitCloseOrder()} disabled={gameEnded || positionAction || invalidCloseOrder || snapshot.position.side !== "SHORT"}>{positionAction ? "提交中…" : "平空"}</button><button type="button" className="paper-short-button" onClick={() => void submitCloseOrder()} disabled={gameEnded || positionAction || invalidCloseOrder || snapshot.position.side !== "LONG"}>{positionAction ? "提交中…" : "平多"}</button></div>
                <div className="paper-order-capacity"><span>可平</span><strong>{formatNumber(snapshot.position.quantity, 6)} {baseAsset}</strong></div>
                <small>{closeOrderType === "MARKET" ? "按当前已揭示 K 线收盘价成交。" : "多仓限价低于或等于当前价、空仓限价高于或等于当前价时，按当前收盘价立即成交；否则作为止盈委托。"}</small>
              </> : <div className="paper-close-empty">当前没有可平仓的持仓</div>}
            </div>
          }
          <div className="paper-order-account-wrap"><span>账户</span><dl className="paper-order-account">
              <div><dt>账户余额</dt><dd>{formatNumber(snapshot.balance, 2)} USDT</dd></div>
              <div><dt>账户权益</dt><dd>{formatNumber(snapshot.equity, 2)} USDT</dd></div>
              <div><dt>可用余额</dt><dd>{formatNumber(snapshot.available_balance, 2)} USDT</dd></div>
              <div><dt>持仓价值</dt><dd>{formatNumber(positionNotional, 2)} USDT</dd></div>
              <div><dt>实际杠杆</dt><dd>{formatNumber(actualLeverage, 2)}x</dd></div>
              <div><dt>维持保证金</dt><dd>{formatNumber(maintenanceMargin, 2)} USDT</dd></div>
              <div><dt>未实现盈亏</dt><dd className={pnl >= 0 ? "paper-long-price" : "paper-short-price"}>{pnl >= 0 ? "+" : ""}{formatNumber(pnl, 2)} USDT</dd></div>
              <div><dt>已实现盈亏</dt><dd className={snapshot.realized_pnl >= 0 ? "paper-long-price" : "paper-short-price"}>{snapshot.realized_pnl >= 0 ? "+" : ""}{formatNumber(snapshot.realized_pnl, 2)} USDT</dd></div>
            </dl></div>
        </aside>
      </section>
      {riskDialogOpen && snapshot.position && <div className="paper-risk-backdrop" role="presentation">
        <section className="paper-risk-dialog" role="dialog" aria-labelledby="paper-risk-title" style={{ transform: `translate3d(${riskDialogOffset.x}px, ${riskDialogOffset.y}px, 0)` }}>
          <header onPointerDown={startRiskDialogDrag} onPointerMove={moveRiskDialog} onPointerUp={stopRiskDialogDrag} onPointerCancel={stopRiskDialogDrag}><h2 id="paper-risk-title">整仓止盈/止损</h2><button type="button" onClick={() => setRiskDialogOpen(false)} aria-label="关闭止盈止损设置">×</button></header>
          <div className="paper-risk-notice">ⓘ 在剧烈波动行情中，如果止损触发价过于接近强平价，订单可能无法成功执行。</div>
          <dl className="paper-risk-position-summary">
            <div><dt>合约</dt><dd className={snapshot.position.side === "LONG" ? "paper-long-price" : "paper-short-price"}>{snapshot.symbol} 永续 / {snapshot.position.side === "LONG" ? "多" : "空"} {snapshot.position.leverage}x</dd></div>
            <div><dt>开仓均价</dt><dd>{formatNumber(snapshot.position.entry_price, 2)} USDT</dd></div>
            <div><dt>当前价</dt><dd>{formatNumber(snapshot.position.mark_price, 2)} USDT</dd></div>
          </dl>
          <div className="paper-risk-field">
            <div className="paper-risk-field-heading"><span>触发价格 (USDT)</span><span>预计盈亏 (USDT)</span></div>
            <div className="paper-risk-field-title"><strong>止盈价格</strong><button type="button" onClick={() => { setRiskDialogError(null); setAutoTwoRTakeProfit(false); setTakeProfit(""); }}>取消</button></div>
            <div className="paper-risk-input-row"><input aria-label="止盈价格" type="number" min="0" step="0.01" value={takeProfit} onChange={(event) => { setRiskDialogError(null); setAutoTwoRTakeProfit(false); setTakeProfit(event.target.value === "" ? "" : Number(event.target.value)); }} placeholder="--" /><output className={projectedTakeProfit === null ? "" : projectedTakeProfit >= 0 ? "paper-long-price" : "paper-short-price"}>{projectedTakeProfit === null ? "--" : `${projectedTakeProfit >= 0 ? "+" : ""}${formatNumber(projectedTakeProfit, 2)}`}</output></div>
            <p>当最新价达到设定价格时，将按当前 K 线收盘价平仓。</p>
          </div>
          <div className="paper-risk-field">
            <div className="paper-risk-field-title"><strong>止损价格</strong><button type="button" onClick={() => updateStopLoss("")}>取消</button></div>
            <div className="paper-risk-input-row"><input aria-label="止损价格" type="number" min="0" step="0.01" value={stopLoss} onChange={(event) => updateStopLoss(event.target.value)} placeholder="--" /><output className={projectedStopLoss === null ? "" : projectedStopLoss >= 0 ? "paper-long-price" : "paper-short-price"}>{projectedStopLoss === null ? "--" : `${projectedStopLoss >= 0 ? "+" : ""}${formatNumber(projectedStopLoss, 2)}`}</output></div>
            <p>当最新价达到设定价格时，将按当前 K 线收盘价平仓。</p>
          </div>
          {riskDialogError && <div className="paper-risk-error" role="alert">{riskDialogError}</div>}
          <footer><button type="button" onClick={() => void saveRiskOrders()} disabled={positionAction}>{positionAction ? "保存中…" : "确认"}</button></footer>
        </section>
      </div>}
    </>}
  </main>;
}

function AuthScreen({ onAuthenticated }: { onAuthenticated: (user: CurrentUser) => void }) {
  const [mode, setMode] = useState<"login" | "register">("login");
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (mode === "register" && password !== confirmation) {
      setError("两次输入的密码不一致");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const response = await fetch(`/api/auth/${mode}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(mode === "login" ? { identifier, password } : { email: identifier, password })
      });
      const body = await response.json() as CurrentUser | { detail?: string };
      if (!response.ok) throw new Error(paperErrorMessage(body, `请求失败 (HTTP ${response.status})`));
      onAuthenticated(body as CurrentUser);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "登录失败");
    } finally {
      setSubmitting(false);
    }
  }

  function switchMode(next: "login" | "register") {
    setMode(next);
    setPassword("");
    setConfirmation("");
    setError(null);
  }

  return <main className="auth-page">
    <section className="auth-card">
      <div className="auth-intro">
        <p className="brand-mark">AUTO TRADE 2.0</p>
        <h1>训练你的交易决策</h1>
        <p>登录后使用行情研究、策略回测和 PaperTrader。新账户会获得 1000 USDT 模拟余额。</p>
        <div className="auth-balance-promise"><span>新用户模拟资金</span><strong>1,000.00 USDT</strong></div>
      </div>
      <form className="auth-form" onSubmit={(event) => void submit(event)}>
        <div className="auth-mode-switch">
          <button type="button" className={mode === "login" ? "active" : ""} onClick={() => switchMode("login")}>登录</button>
          <button type="button" className={mode === "register" ? "active" : ""} onClick={() => switchMode("register")}>注册</button>
        </div>
        <div><p className="eyebrow">{mode === "login" ? "WELCOME BACK" : "CREATE ACCOUNT"}</p><h2>{mode === "login" ? "登录账户" : "创建新账户"}</h2></div>
        {error && <div className="alert alert-critical">{error}</div>}
        <label><span>{mode === "login" ? "邮箱或用户名" : "邮箱"}</span><input type={mode === "login" ? "text" : "email"} autoComplete="username" value={identifier} onChange={(event) => setIdentifier(event.target.value)} placeholder={mode === "login" ? "邮箱，或管理员用户名 Admin" : "name@example.com"} required /></label>
        <label><span>密码</span><input type="password" minLength={8} maxLength={128} autoComplete={mode === "login" ? "current-password" : "new-password"} value={password} onChange={(event) => setPassword(event.target.value)} placeholder="至少 8 位" required /></label>
        {mode === "register" && <label><span>确认密码</span><input type="password" minLength={8} maxLength={128} autoComplete="new-password" value={confirmation} onChange={(event) => setConfirmation(event.target.value)} placeholder="再次输入密码" required /></label>}
        <button className="primary-button auth-submit" type="submit" disabled={submitting}>{submitting ? "处理中…" : mode === "login" ? "登录" : "注册并领取 1000 USDT"}</button>
        <small>当前版本无需邮箱验证。密码经过加盐哈希后保存，系统不会存储明文密码。</small>
      </form>
    </section>
  </main>;
}

function UserManagementWorkspace() {
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [updating, setUpdating] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void fetch("/api/admin/users", { cache: "no-store" })
      .then(async (response) => {
        const body = await response.json() as AdminUser[] | { detail?: string };
        if (!response.ok) throw new Error(paperErrorMessage(body, "用户列表加载失败"));
        setUsers(body as AdminUser[]);
      })
      .catch((reason: unknown) => setError(reason instanceof Error ? reason.message : "用户列表加载失败"))
      .finally(() => setLoading(false));
  }, []);

  async function updateRole(userId: string, role: "NORMAL" | "ADVANCED") {
    setUpdating(userId);
    setError(null);
    try {
      const response = await fetch(`/api/admin/users/${userId}/role`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ role })
      });
      const body = await response.json() as AdminUser | { detail?: string };
      if (!response.ok) throw new Error(paperErrorMessage(body, "用户等级更新失败"));
      const updated = body as AdminUser;
      setUsers((current) => current.map((user) => user.user_id === updated.user_id ? updated : user));
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "用户等级更新失败");
    } finally {
      setUpdating(null);
    }
  }

  return <main className="admin-page">
    <header className="topbar"><div><p className="brand-mark">ADMINISTRATION</p><h1>用户管理</h1><p className="subtitle">查看用户账户并管理普通用户与高级用户等级。</p></div></header>
    {error && <div className="alert alert-critical">{error}</div>}
    <section className="panel account-history-panel">
      <div className="panel-heading"><div><p className="eyebrow">USERS</p><h3>系统用户</h3></div><strong>{users.length} 位</strong></div>
      {loading ? <div className="loading">正在读取用户列表…</div> : <div className="table-scroll"><table className="storage-table admin-user-table"><thead><tr><th>用户</th><th>等级</th><th>注册时间 UTC+8</th><th>余额</th><th>交易数</th><th>等级管理</th></tr></thead><tbody>{users.map((user) => <tr key={user.user_id}><td><strong>{user.username ?? user.email}</strong>{user.username && <small>{user.email}</small>}</td><td><span className={`user-role role-${user.role.toLowerCase()}`}>{user.role === "NORMAL" ? "普通用户" : user.role === "ADVANCED" ? "高级用户" : "管理员"}</span></td><td>{new Date(user.created_at).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false })}</td><td>{formatNumber(user.balance, 2)} USDT</td><td>{user.trade_count}</td><td>{user.role === "ADMIN" ? <span className="admin-locked">不可修改</span> : <select value={user.role} onChange={(event) => void updateRole(user.user_id, event.target.value as "NORMAL" | "ADVANCED")} disabled={updating === user.user_id}><option value="NORMAL">普通用户</option><option value="ADVANCED">高级用户</option></select>}</td></tr>)}</tbody></table></div>}
    </section>
  </main>;
}

function AccountWorkspace({ user, onAccountChange }: { user: CurrentUser; onAccountChange: (account: AccountSummary) => void }) {
  const [history, setHistory] = useState<AccountTradeHistory | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setLoading(true);
    void fetch("/api/account/trades?limit=500", { cache: "no-store" })
      .then(async (response) => {
        const body = await response.json() as AccountTradeHistory | { detail?: string };
        if (!response.ok) throw new Error(paperErrorMessage(body, "账户记录加载失败"));
        const value = body as AccountTradeHistory;
        setHistory(value);
        onAccountChange(value.account);
      })
      .catch((reason: unknown) => setError(reason instanceof Error ? reason.message : "账户记录加载失败"))
      .finally(() => setLoading(false));
  }, []);

  const account = history?.account ?? user.account;
  return <main className="account-page">
    <header className="topbar"><div><p className="brand-mark">MY ACCOUNT</p><h1>模拟账户</h1><p className="subtitle">{user.username ?? user.email} · {user.role === "NORMAL" ? "普通用户" : user.role === "ADVANCED" ? "高级用户" : "管理员"} · 注册于 {new Date(user.created_at).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" })}</p></div></header>
    <section className="paper-account-grid">
      <article className="summary-card"><span>当前余额</span><strong>{formatNumber(account.balance, 2)}</strong><em>USDT</em></article>
      <article className="summary-card"><span>初始资金</span><strong>{formatNumber(account.starting_balance, 2)}</strong><em>USDT</em></article>
      <article className="summary-card"><span>累计已实现盈亏</span><strong className={profitClass(account.realized_pnl)}>{account.realized_pnl >= 0 ? "+" : ""}{formatNumber(account.realized_pnl, 2)}</strong><em>USDT</em></article>
      <article className="summary-card"><span>累计成交</span><strong>{account.trade_count}</strong><em>笔已平仓交易</em></article>
    </section>
    <section className="panel account-history-panel">
      <div className="panel-heading"><div><p className="eyebrow">TRADE HISTORY</p><h3>全部模拟交易记录</h3></div></div>
      {loading ? <div className="loading">正在读取账户记录…</div> : error ? <div className="alert alert-critical">{error}</div> : history?.trades.length ? <div className="table-scroll account-history-scroll"><table className="storage-table account-history-table"><thead><tr><th>平仓时间 UTC+8</th><th>交易对</th><th>方向</th><th>杠杆</th><th>数量</th><th>开仓价</th><th>平仓价</th><th>已实现盈亏</th><th>平仓后余额</th><th>原因</th></tr></thead><tbody>{history.trades.map((trade) => <tr key={trade.trade_id}><td>{new Date(trade.closed_at).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai", hour12: false })}</td><td>{trade.symbol}</td><td className={trade.side === "LONG" ? "paper-long-price" : "paper-short-price"}>{trade.side === "LONG" ? "多" : "空"}</td><td>{trade.leverage}x</td><td>{formatNumber(trade.quantity, 6)}</td><td>{formatNumber(trade.entry_price, 2)}</td><td>{formatNumber(trade.exit_price, 2)}</td><td className={profitClass(trade.realized_pnl)}>{trade.realized_pnl >= 0 ? "+" : ""}{formatNumber(trade.realized_pnl, 2)}</td><td>{formatNumber(trade.balance_after, 2)}</td><td>{trade.exit_reason}</td></tr>)}</tbody></table></div> : <div className="account-history-empty">暂无交易记录，前往交易模拟器开始第一笔练习。</div>}
    </section>
  </main>;
}

type WorkspaceView = "rankings" | "backtest" | "paper" | "monitoring" | "account" | "admin";

function App() {
  const [user, setUser] = useState<CurrentUser | null>(null);
  const [authLoading, setAuthLoading] = useState(true);
  const [view, setView] = useState<WorkspaceView>("paper");

  useEffect(() => {
    void fetch("/api/auth/me", { cache: "no-store" })
      .then(async (response) => {
        if (response.status === 401) return null;
        const body = await response.json() as CurrentUser | { detail?: string };
        if (!response.ok) throw new Error(paperErrorMessage(body, "账户状态读取失败"));
        return body as CurrentUser;
      })
      .then((value) => {
        setUser(value);
        if (value?.role !== "NORMAL") setView("rankings");
      })
      .catch(() => setUser(null))
      .finally(() => setAuthLoading(false));
  }, []);

  async function logout() {
    await fetch("/api/auth/logout", { method: "POST" });
    setUser(null);
    setView("paper");
  }

  function updateAccount(account: AccountSummary) {
    setUser((current) => current ? { ...current, account } : current);
  }

  function updateBalance(balance: number) {
    setUser((current) => current ? { ...current, account: { ...current.account, balance, realized_pnl: balance - current.account.starting_balance } } : current);
  }

  if (authLoading) return <main className="auth-loading"><div className="loading">正在检查登录状态…</div></main>;
  if (!user) return <AuthScreen onAuthenticated={setUser} />;
  return <>
    <div className="workspace-header">
      <nav className="workspace-tabs" aria-label="工具导航">
        {user.role !== "NORMAL" && <button className={view === "rankings" ? "active" : ""} onClick={() => setView("rankings")}>数据查询</button>}
        {user.role !== "NORMAL" && <button className={view === "backtest" ? "active" : ""} onClick={() => setView("backtest")}>策略回测</button>}
        <button className={view === "paper" ? "active" : ""} onClick={() => setView("paper")}>交易模拟器</button>
        {user.role !== "NORMAL" && <button className={view === "monitoring" ? "active" : ""} onClick={() => setView("monitoring")}>采集监控</button>}
        {user.role === "ADMIN" && <button className={view === "admin" ? "active" : ""} onClick={() => setView("admin")}>用户管理</button>}
      </nav>
      <div className="workspace-user"><button type="button" className={view === "account" ? "active" : ""} onClick={() => setView("account")}><span>{user.email}</span><strong>{formatNumber(user.account.balance, 2)} USDT</strong></button><button type="button" onClick={() => void logout()}>退出</button></div>
    </div>
    {view === "rankings" ? <RankingExplorer /> : view === "backtest" ? <BacktestWorkspace /> : view === "paper" ? <PaperTraderWorkspace onBalanceChange={updateBalance} /> : view === "account" ? <AccountWorkspace user={user} onAccountChange={updateAccount} /> : view === "admin" ? <UserManagementWorkspace /> : <MonitoringDashboard />}
  </>;
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode><App /></React.StrictMode>
);
