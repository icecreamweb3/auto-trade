from __future__ import annotations

import logging
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path

from auto_trade.config import Settings

LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"


def configure_logging(
    settings: Settings,
    component: str,
    *,
    target_logger: logging.Logger | None = None,
) -> Path | None:
    """Configure console logging and optional UTC daily file rotation."""
    logger = target_logger or logging.getLogger()
    logger.setLevel(settings.log_level)
    formatter = logging.Formatter(LOG_FORMAT)

    if not logger.handlers:
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(formatter)
        logger.addHandler(console_handler)

    if not settings.file_log_enabled:
        return None

    directory = Path(settings.file_log_directory)
    directory.mkdir(parents=True, exist_ok=True)
    log_path = directory / f"{component}.log"
    resolved_path = log_path.resolve()
    for handler in logger.handlers:
        if (
            isinstance(handler, TimedRotatingFileHandler)
            and Path(handler.baseFilename).resolve() == resolved_path
        ):
            return log_path

    file_handler = TimedRotatingFileHandler(
        log_path,
        when="midnight",
        interval=1,
        backupCount=settings.file_log_retention_days,
        encoding="utf-8",
        delay=True,
        utc=True,
    )
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    logger.info(
        "file logging enabled component=%s path=%s retention_days=%d",
        component,
        log_path,
        settings.file_log_retention_days,
    )
    return log_path
