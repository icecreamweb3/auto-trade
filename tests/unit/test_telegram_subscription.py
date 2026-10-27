from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import AsyncMock, MagicMock

import pytest
from pydantic import SecretStr

from auto_trade.collectors.telegram_client import telegram_proxy
from auto_trade.collectors.telegram_repository import (
    TelegramMessageRecord,
    TelegramMessageRepository,
)
from auto_trade.collectors.telegram_signals import (
    TelegramSignalDirection,
    TelegramSignalKind,
    bwe_chinese_display_text,
    parse_bwe_oi_price_message,
    parse_wizzalert_message,
)
from auto_trade.collectors.telegram_subscriber import _backfill, _message_record
from auto_trade.config import Settings


def test_parse_wizzalert_continuation_without_confusing_parent_entry() -> None:
    signal = parse_wizzalert_message(
        """🟢 PUMPBTC · +23.1% (24h)
────────
↗️ 续涨 · 分 60 · 初推 2.4h前
市场
5m +1.9% · 1h +8.6% · vol 21.7\u00d7 · OI +4.2%
动作
↪ 接续 2.4h前 的 晚追入场 → 现在 同向延续"""
    )

    assert signal.symbol_raw == "PUMPBTC"
    assert signal.symbol == "PUMPBTCUSDT"
    assert signal.signal_kind is TelegramSignalKind.CONTINUATION
    assert signal.direction is TelegramSignalDirection.LONG
    assert signal.score == 60
    assert signal.metrics == {
        "change_5m_percent": 1.9,
        "change_1h_percent": 8.6,
        "change_24h_percent": 23.1,
        "volume_multiple": 21.7,
        "open_interest_change_percent": 4.2,
    }
    assert signal.is_actionable is False


def test_parse_wizzalert_explicit_entry_candidate() -> None:
    signal = parse_wizzalert_message(
        """🔻 TEST · -8.2% (24h)
────────
晚追入场 · 分 55 · 触发 1h跌幅 (做空 🔻)
动作
🎯 等待下一根 K 线确认"""
    )

    assert signal.symbol == "TESTUSDT"
    assert signal.signal_kind is TelegramSignalKind.ENTRY
    assert signal.direction is TelegramSignalDirection.SHORT
    assert signal.score == 55
    assert signal.action_text == "🎯 等待下一根 K 线确认"
    assert signal.is_actionable is True


def test_parse_wizzalert_non_entry_messages_are_not_actionable() -> None:
    reversal = parse_wizzalert_message(
        """🎯 QI · +20.2% (24h)
────────
🎯 多头侧反转预警 · 分 50
动作
🎯 考虑止盈 / 减仓"""
    )
    wake = parse_wizzalert_message(
        """🌅 龙虾 · +3.2% (24h)
────────
🌅 波动率苏醒 · 双向警惕 · 🟡 观望 · 分 45"""
    )

    assert reversal.signal_kind is TelegramSignalKind.REVERSAL_WARNING
    assert reversal.direction is TelegramSignalDirection.LONG
    assert reversal.is_actionable is False
    assert wake.signal_kind is TelegramSignalKind.VOLATILITY_WAKE
    assert wake.direction is TelegramSignalDirection.NEUTRAL
    assert wake.symbol is None


def test_parse_bwe_oi_price_message_and_show_only_chinese_summary() -> None:
    text = (
        "🇨🇳 🟢 [DOODUSDT] 币安未平仓合约量 +10.2%\uFF0C"
        "过去 3600 秒价格上涨 25.6%\uFF0C"
        "未平仓合约量\uFF1A920 万美元\uFF0C"
        "未平仓合约量/市值比率\uFF1A58.2%\uFF0C"
        "24 小时价格变动\uFF1A+55.0%\n"
        "🇺🇸 🟢 [DOODUSDT] Binance openinterest +10.2%, "
        "Price +25.6% in the past 3600 seconds, OI: $9.2M, "
        "OI/Marketcap ratio: 58.2%, 24H Price Change: +55.0%\n\n"
        "💰 市值\nDOOD  MarketCap: 19M"
    )

    signal = parse_bwe_oi_price_message(text)
    display_text = bwe_chinese_display_text(text)

    assert signal.parser_version == "bwe-oi-price-v1"
    assert signal.symbol_raw == "DOODUSDT"
    assert signal.symbol == "DOODUSDT"
    assert signal.signal_kind is TelegramSignalKind.VOLATILITY_WAKE
    assert signal.direction is TelegramSignalDirection.LONG
    assert signal.is_actionable is False
    assert signal.metrics == {
        "open_interest_change_percent": 10.2,
        "price_change_percent": 25.6,
        "window_seconds": 3600.0,
        "open_interest_usd": 9_200_000.0,
        "oi_marketcap_ratio_percent": 58.2,
        "change_24h_percent": 55.0,
        "market_cap_usd": 19_000_000.0,
    }
    assert "币安未平仓合约量" in display_text
    assert "Binance openinterest" not in display_text
    assert "DOOD 市值\uFF1A1900 万美元" in display_text


def test_bwe_message_record_preserves_raw_text_but_exposes_chinese_text() -> None:
    raw_text = """🇨🇳 🟢 [DOODUSDT] 中文告警
🇺🇸 🟢 [DOODUSDT] English alert"""
    posted_at = datetime(2026, 10, 26, tzinfo=UTC)
    message = MagicMock()
    message.id = 42
    message.date = posted_at
    message.edit_date = None
    message.grouped_id = None
    message.reply_to_msg_id = None
    message.media = None
    message.message = raw_text

    record = _message_record(
        123,
        "BWE_OI_Price_monitor",
        message,
        posted_at,
    )

    assert record.message_text == "🇨🇳 🟢 [DOODUSDT] 中文告警"
    assert record.raw_payload["message_text"] == raw_text


async def test_initial_telegram_backfill_starts_at_configured_time() -> None:
    async def no_messages():
        if False:
            yield None

    start_at = datetime.fromisoformat("2026-10-01T00:00:00+08:00")
    client = MagicMock()
    client.iter_messages.return_value = no_messages()
    processor = MagicMock(channel_id=123)
    processor.process = AsyncMock()
    repository = MagicMock()
    repository.latest_message_id = AsyncMock(return_value=None)
    repository.mark_history_complete = AsyncMock()
    settings = MagicMock()
    entity = MagicMock()

    processed = await _backfill(
        client,
        entity,
        processor,
        repository,
        settings,
        start_at,
    )

    assert processed == 0
    client.iter_messages.assert_called_once_with(
        entity,
        reverse=True,
        offset_date=start_at,
    )
    repository.mark_history_complete.assert_awaited_once_with(123)


def test_telegram_proxy_prefers_dedicated_configuration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ALL_PROXY", "http://fallback.example:8080")
    settings = Settings(  # type: ignore[call-arg]
        _env_file=None,
        postgres_password=SecretStr("test-password"),
        telegram_proxy_url=SecretStr("socks5://user:pass@127.0.0.1:1080"),
    )

    assert telegram_proxy(settings) == (
        "socks5",
        "127.0.0.1",
        1080,
        True,
        "user",
        "pass",
    )


async def test_unchanged_message_still_refreshes_parser_output() -> None:
    unchanged = MagicMock()
    unchanged.scalar_one_or_none.return_value = None
    connection = MagicMock()
    connection.execute = AsyncMock(side_effect=[unchanged, MagicMock()])
    engine = MagicMock()
    engine.begin.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.begin.return_value.__aexit__ = AsyncMock(return_value=None)
    now = datetime(2026, 10, 26, tzinfo=UTC)
    record = TelegramMessageRecord(
        channel_id=123,
        message_id=456,
        posted_at=now,
        edited_at=None,
        grouped_id=None,
        reply_to_message_id=None,
        message_text="test",
        media_type=None,
        raw_payload={"message_id": 456, "message_text": "test"},
        collected_at=now,
    )

    changed = await TelegramMessageRepository(engine).store(
        record,
        parse_wizzalert_message(record.message_text),
    )

    assert changed is False
    assert connection.execute.await_count == 2
    signal_statement = str(connection.execute.await_args_list[1].args[0])
    assert "INSERT INTO market.telegram_signals" in signal_statement
