import React, { useEffect, useState } from "react";
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
    message: string;
  };
  rest_usage: {
    status: HealthStatus;
    request_rate_1m: number | null;
    used_weight_1m: number | null;
    limit_1m: number;
    utilization_percent: number | null;
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

function App() {
  const [data, setData] = useState<MonitoringSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  async function refresh() {
    try {
      const response = await fetch("/api/monitoring/overview", { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      setData((await response.json()) as MonitoringSnapshot);
      setError(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "无法连接监控服务");
    } finally {
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
              <span>REST权重</span>
              <strong>{data.rest_usage.used_weight_1m ?? "—"}<em> / {data.rest_usage.limit_1m}</em></strong>
              <small>{data.rest_usage.utilization_percent ?? 0}% · {data.rest_usage.message}</small>
            </article>
          </section>

          {data.notices.map((notice) => <div className="alert" key={notice}>{notice}</div>)}

          <section>
            <div className="section-title"><p className="eyebrow">核心链路</p><h2>实时数据完整性</h2></div>
            <div className="coverage-grid">
              {data.coverage.map((metric) => <CoverageCard key={metric.key} metric={metric} />)}
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
              <dl className="repair-details">
                <div><dt>近1小时成功</dt><dd>{data.backfill.succeeded_last_hour} 个</dd></div>
                <div><dt>近1小时新增</dt><dd>{data.backfill.created_last_hour} 个</dd></div>
                <div><dt>新增−结束（1h）</dt><dd className={data.backfill.queue_delta_last_hour > 0 ? "trend-up" : "trend-down"}>{formatDelta(data.backfill.queue_delta_last_hour)}</dd></div>
                <div><dt>预计清空</dt><dd>{formatAge(data.backfill.estimated_clear_seconds)}</dd></div>
                <div><dt>最近成功</dt><dd>{formatUtc(data.backfill.last_succeeded_at)}</dd></div>
                <div><dt>最老等待</dt><dd>{formatAge(data.backfill.oldest_pending_seconds)}</dd></div>
              </dl>
              <p className="message">开放缺口 {data.backfill.open_gaps} · {data.backfill.message}</p>
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

createRoot(document.getElementById("root")!).render(
  <React.StrictMode><App /></React.StrictMode>
);
