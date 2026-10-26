from datetime import UTC, datetime
from unittest.mock import AsyncMock, MagicMock

from auto_trade.messages.repository import MessageRepository, message_title


def test_message_title_uses_first_non_empty_line() -> None:
    assert message_title("\n  🟢 BTC · +3.2%  \ncontent", 12) == "🟢 BTC · +3.2%"
    assert message_title("\n\n", 12) == "消息 #12"


async def test_message_repository_returns_channel_page() -> None:
    posted_at = datetime(2026, 10, 26, 6, 30, tzinfo=UTC)
    channel_result = MagicMock()
    channel_result.mappings.return_value.one_or_none.return_value = {
        "channel_id": 3990120250,
        "username": "wizzalert",
        "title": "Wizz Alert",
        "history_complete": True,
        "last_realtime_at": None,
        "message_count": 7066,
        "earliest_message_at": datetime(2026, 4, 15, tzinfo=UTC),
        "latest_message_at": posted_at,
    }
    messages_result = MagicMock()
    messages_result.mappings.return_value.all.return_value = [
        {
            "channel_id": 3990120250,
            "message_id": 7914,
            "posted_at": posted_at,
            "edited_at": None,
            "message_text": "🌅 TOSHI · +3.8% (24h)\n消息内容",
            "media_type": None,
            "symbol": "TOSHIUSDT",
            "signal_kind": "VOLATILITY_WAKE",
            "direction": "NEUTRAL",
            "score": 45,
            "change_24h_percent": 3.8,
            "is_actionable": False,
        }
    ]
    count_result = MagicMock()
    count_result.scalar_one.return_value = 696
    connection = MagicMock()
    connection.execute = AsyncMock(
        side_effect=[channel_result, count_result, messages_result]
    )
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)

    result = await MessageRepository(engine).messages(
        channel_id=3990120250,
        page=2,
        page_size=20,
        signal_kind="VOLATILITY_WAKE",
    )

    assert result is not None
    assert result.channel.username == "wizzalert"
    assert result.total == 696
    assert result.signal_kind == "VOLATILITY_WAKE"
    assert result.items[0].title == "🌅 TOSHI · +3.8% (24h)"
    assert result.items[0].signal_kind == "VOLATILITY_WAKE"
    assert result.items[0].change_24h_percent == 3.8
    assert connection.execute.await_args_list[2].args[1]["offset"] == 20
    assert connection.execute.await_args_list[2].args[1]["signal_kind"] == "VOLATILITY_WAKE"
