from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import unquote, urlparse

from telethon import TelegramClient  # type: ignore[import-untyped]

from auto_trade.config import Settings

TelegramProxy = tuple[str, str, int, bool, str | None, str | None]


def telegram_proxy(settings: Settings) -> TelegramProxy:
    configured = (
        settings.telegram_proxy_url.get_secret_value()
        if settings.telegram_proxy_url is not None
        else None
    )
    proxy_url = configured or os.getenv("ALL_PROXY") or os.getenv("HTTPS_PROXY")
    proxy_url = proxy_url or os.getenv("HTTP_PROXY")
    if not proxy_url:
        raise RuntimeError("Telegram proxy is required but no proxy URL is configured")
    parsed = urlparse(proxy_url)
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "socks4", "socks5"}:
        raise ValueError("Telegram proxy scheme must be http, socks4 or socks5")
    if parsed.hostname is None or parsed.port is None:
        raise ValueError("Telegram proxy URL must include a host and port")
    return (
        scheme,
        parsed.hostname,
        parsed.port,
        True,
        unquote(parsed.username) if parsed.username else None,
        unquote(parsed.password) if parsed.password else None,
    )


def telegram_credentials(settings: Settings) -> tuple[int, str]:
    if settings.telegram_api_id is None or settings.telegram_api_hash is None:
        raise RuntimeError("TELEGRAM_API_ID and TELEGRAM_API_HASH are required")
    return settings.telegram_api_id, settings.telegram_api_hash.get_secret_value()


def build_telegram_client(settings: Settings) -> TelegramClient:
    api_id, api_hash = telegram_credentials(settings)
    session_path = Path(settings.telegram_session_path)
    session_path.parent.mkdir(parents=True, exist_ok=True)
    return TelegramClient(
        str(session_path),
        api_id,
        api_hash,
        proxy=telegram_proxy(settings),
        connection_retries=3,
        retry_delay=settings.telegram_reconnect_delay_seconds,
        auto_reconnect=True,
        catch_up=True,
    )


def protect_session_file(settings: Settings) -> None:
    configured = Path(settings.telegram_session_path)
    candidates = (configured, Path(f"{configured}.session"))
    for candidate in candidates:
        if candidate.exists():
            candidate.chmod(0o600)
