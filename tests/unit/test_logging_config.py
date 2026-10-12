import logging
from pathlib import Path

from pydantic import SecretStr

from auto_trade.config import Settings
from auto_trade.logging_config import configure_logging


def test_file_logging_can_be_disabled(tmp_path: Path) -> None:
    settings = Settings(
        _env_file=None,
        postgres_password=SecretStr("test-password"),
        file_log_enabled=False,
        file_log_directory=str(tmp_path),
    )
    logger = logging.getLogger("test-file-logging-disabled")
    logger.handlers.clear()
    logger.propagate = False

    assert configure_logging(settings, "collector", target_logger=logger) is None
    assert not (tmp_path / "collector.log").exists()


def test_file_logging_writes_component_log(tmp_path: Path) -> None:
    settings = Settings(
        _env_file=None,
        postgres_password=SecretStr("test-password"),
        file_log_enabled=True,
        file_log_directory=str(tmp_path),
        file_log_retention_days=7,
    )
    logger = logging.getLogger("test-file-logging-enabled")
    logger.handlers.clear()
    logger.propagate = False

    log_path = configure_logging(settings, "collector", target_logger=logger)
    logger.warning("websocket diagnostic marker")
    for handler in logger.handlers:
        handler.flush()

    assert log_path == tmp_path / "collector.log"
    assert "websocket diagnostic marker" in (tmp_path / "collector.log").read_text()

    for handler in logger.handlers:
        handler.close()
    logger.handlers.clear()
