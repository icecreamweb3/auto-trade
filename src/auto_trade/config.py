from functools import lru_cache
from typing import Literal
from urllib.parse import quote_plus

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Deployment settings only; strategy parameters do not belong here."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    environment: Literal["DEV", "TEST", "SHADOW", "PROD"] = "DEV"
    service_name: str = "auto-trade-api"
    node_id: str = "local-1"
    shard_id: str = "0"

    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    file_log_enabled: bool = False
    file_log_directory: str = "/var/log/auto-trade"
    file_log_retention_days: int = Field(default=14, ge=1, le=90)

    postgres_host: str = "127.0.0.1"
    postgres_port: int = Field(default=5432, ge=1, le=65535)
    postgres_db: str = "auto_trade"
    postgres_user: str = "auto_trade_admin"
    postgres_password: SecretStr

    nats_url: str = "nats://127.0.0.1:4222"
    binance_usdm_base_url: str = "https://fapi.binance.com"
    binance_usdm_websocket_url: str = "wss://fstream.binance.com"
    binance_request_timeout_seconds: float = Field(default=10.0, gt=0, le=60)
    binance_max_concurrency: int = Field(default=8, ge=1, le=32)
    binance_request_attempts: int = Field(default=3, ge=1, le=5)
    collector_startup_delay_seconds: float = Field(default=5.0, ge=0, le=60)
    collector_boundary_delay_seconds: float = Field(default=15.0, ge=0, le=30)
    instrument_sync_utc_hour: int = Field(default=16, ge=0, le=23)
    websocket_streams_per_connection: int = Field(default=100, ge=2, le=1000)
    websocket_reconnect_max_seconds: float = Field(default=30.0, ge=1, le=300)
    websocket_receive_timeout_seconds: float = Field(default=60.0, ge=30, le=300)
    websocket_message_queue_size: int = Field(default=4096, ge=100, le=65536)
    websocket_kline_workers_per_connection: int = Field(default=4, ge=1, le=32)
    websocket_mark_publish_concurrency: int = Field(default=32, ge=1, le=128)
    monitoring_data_safety_delay_seconds: int = Field(default=30, ge=0, le=300)
    daily_ranking_scan_interval_seconds: int = Field(default=300, ge=60, le=3600)
    daily_ranking_lookback_days: int = Field(default=90, ge=1, le=366)
    daily_ranking_max_days_per_cycle: int = Field(default=7, ge=1, le=31)
    ema_indicator_scan_interval_seconds: int = Field(default=300, ge=30, le=3600)
    ema_indicator_write_batch_size: int = Field(default=1000, ge=100, le=10000)
    gap_scan_lookback_hours: int = Field(default=2160, ge=1, le=2160)
    gap_scan_recent_lookback_hours: int = Field(default=24, ge=1, le=168)
    gap_scan_historical_window_hours: int = Field(default=24, ge=1, le=168)
    gap_scan_interval_seconds: int = Field(default=300, ge=60, le=3600)
    gap_scan_safety_delay_seconds: int = Field(default=60, ge=0, le=600)
    gap_scan_statement_timeout_seconds: int = Field(default=45, ge=5, le=600)
    backfill_jobs_per_cycle: int = Field(default=50, ge=1, le=500)
    backfill_worker_count: int = Field(default=4, ge=1, le=16)
    backfill_verify_timeout_seconds: float = Field(default=60.0, ge=5, le=300)
    backfill_verify_poll_interval_seconds: float = Field(
        default=1.0, ge=0.1, le=10
    )
    backfill_stale_job_seconds: int = Field(default=300, ge=30, le=3600)
    backfill_failed_retry_limit: int = Field(default=3, ge=1, le=10)
    backfill_request_interval_seconds: float = Field(default=2.0, ge=0.1, le=60)
    backfill_rate_limit_cooldown_seconds: float = Field(
        default=300.0, ge=60, le=86400
    )
    paper_history_request_interval_seconds: float = Field(
        default=0.5, ge=0, le=60
    )

    @property
    def database_dsn(self) -> str:
        password = quote_plus(self.postgres_password.get_secret_value())
        user = quote_plus(self.postgres_user)
        return (
            f"postgresql+asyncpg://{user}:{password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
