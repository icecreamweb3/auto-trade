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

  return (
    <main>
      <header className="topbar ranking-header">
        <div>
          <p className="brand-mark">MARKET RESEARCH</p>
          <h1>UTC 日涨幅榜查询</h1>
          <p className="subtitle">UTC 00:00 开盘至 23:55 快照 · Binance USDⓈ-M 永续</p>
        </div>
        <div className="data-range-badge">
          <span>本地数据范围</span>
          <strong>{data?.available_first_date ?? "—"} → {data?.available_last_date ?? "—"}</strong>
        </div>
      </header>

      {error && <div className="alert alert-critical">查询失败：{error}</div>}

      <section className="panel query-panel">
        <form onSubmit={(event) => { event.preventDefault(); void load(filters); }}>
          <label><span>开始日期（UTC）</span><input type="date" value={filters.dateFrom} min={data?.available_first_date ?? undefined} max={data?.available_last_date ?? undefined} onChange={(event) => setFilters({ ...filters, dateFrom: event.target.value })} /></label>
          <label><span>结束日期（UTC）</span><input type="date" value={filters.dateTo} min={data?.available_first_date ?? undefined} max={data?.available_last_date ?? undefined} onChange={(event) => setFilters({ ...filters, dateTo: event.target.value })} /></label>
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
        <article className="summary-card"><span>匹配记录</span><strong>{data?.total.toLocaleString() ?? "—"}</strong><small>{data?.matching_days ?? 0} 个 UTC 交易日</small></article>
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
              <thead><tr><th>UTC日期</th><th>排名</th><th>交易对</th><th>涨幅</th><th>开盘价</th><th>快照价</th><th>振幅</th><th>成交额</th><th>OI</th></tr></thead>
              <tbody>
                {data?.items.map((item) => (
                  <tr key={`${item.utc_trade_date}-${item.rank_no}`} className={selected?.utc_trade_date === item.utc_trade_date && selected.rank_no === item.rank_no ? "selected-row" : ""} onClick={() => setSelected(item)}>
                    <td>{item.utc_trade_date}</td><td><span className={`rank-badge rank-${Math.min(item.rank_no, 4)}`}>{item.rank_no}</span></td><td><a className="symbol-link" href={`https://www.binance.com/zh-CN/futures/${encodeURIComponent(item.symbol)}`} target="_blank" rel="noopener noreferrer" title={`在 Binance Futures 查看 ${item.symbol}`}><strong>{item.symbol}</strong><span aria-hidden="true">↗</span></a></td>
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
            <div className="detail-hero"><div><span>#{selected.rank_no}</span><h2>{selected.symbol}</h2><small>{selected.utc_trade_date} · 23:55 UTC</small></div><strong className={changeClass(selected.price_change)}>{selected.price_change >= 0 ? "+" : ""}{selected.price_change.toFixed(4)}%</strong></div>
            <dl className="metric-list">
              <div><dt>UTC 开盘价</dt><dd>{formatNumber(selected.reference_open_price, 10)}</dd></div>
              <div><dt>23:55 快照价</dt><dd>{formatNumber(selected.snapshot_price, 10)}</dd></div>
              <div><dt>日内最高</dt><dd>{formatNumber(selected.period_high_price, 10)}</dd></div>
              <div><dt>日内最低</dt><dd>{formatNumber(selected.period_low_price, 10)}</dd></div>
              <div><dt>日内振幅</dt><dd>{formatNumber(selected.amplitude, 4)}%</dd></div>
              <div><dt>Quote 成交额</dt><dd>{formatNumber(selected.quote_volume, 2)}</dd></div>
              <div><dt>Base 成交量</dt><dd>{formatNumber(selected.base_volume, 2)}</dd></div>
              <div><dt>Open Interest</dt><dd>{formatNumber(selected.open_interest_qty, 4)}</dd></div>
              <div><dt>OI 价值</dt><dd>{formatNumber(selected.open_interest_value, 2)}</dd></div>
              <div><dt>OI 状态</dt><dd>{selected.open_interest_status === "LOCAL_OBSERVATION" ? "本地观测" : "历史不可用"}</dd></div>
            </dl>
            <p className="detail-note">快照时间 {formatUtc(selected.snapshot_at)}。榜单为 5 分钟 K 线重建结果，不冒充当时实时采集快照。</p>
          </> : <p className="message">选择一条记录查看完整指标。</p>}
        </aside>
      </section>
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
