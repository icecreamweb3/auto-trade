from pydantic import SecretStr

from auto_trade.config import Settings


def test_database_dsn_escapes_credentials() -> None:
    settings = Settings(
        _env_file=None,
        postgres_password=SecretStr("a/b:c@d"),
        postgres_user="collector@example",
    )
    assert "collector%40example" in settings.database_dsn
    assert "a%2Fb%3Ac%40d" in settings.database_dsn
    assert "a/b:c@d" not in settings.database_dsn


def test_websocket_resilience_defaults() -> None:
    settings = Settings(
        _env_file=None,
        postgres_password=SecretStr("test-password"),
    )

    assert settings.websocket_streams_per_connection == 100
    assert settings.websocket_receive_timeout_seconds == 60
    assert settings.websocket_message_queue_size == 4096
    assert settings.websocket_kline_workers_per_connection == 4
    assert settings.websocket_mark_publish_concurrency == 32
    assert settings.collector_boundary_delay_seconds == 15
    assert settings.monitoring_data_safety_delay_seconds == 30
    assert settings.daily_ranking_scan_interval_seconds == 300
    assert settings.daily_ranking_lookback_days == 90
    assert settings.daily_ranking_max_days_per_cycle == 7
    assert settings.gap_scan_safety_delay_seconds == 60
    assert settings.gap_scan_lookback_hours == 2160
    assert settings.gap_scan_recent_lookback_hours == 24
    assert settings.gap_scan_historical_window_hours == 24
    assert settings.gap_scan_statement_timeout_seconds == 45


def test_file_logging_defaults_to_disabled() -> None:
    settings = Settings(
        _env_file=None,
        postgres_password=SecretStr("test-password"),
    )

    assert settings.log_level == "INFO"
    assert settings.file_log_enabled is False
    assert settings.file_log_directory == "/var/log/auto-trade"
    assert settings.file_log_retention_days == 14
    assert settings.backfill_worker_count == 4
