from auto_trade.collectors.websocket_klines import (
    MARKET_WIDE_STREAMS,
    chunked,
    format_message_counts,
    kline_stream_names,
    market_stream_names,
    market_stream_shards,
    websocket_connect_options,
    websocket_message_context,
    websocket_proxy,
    websocket_shard_type,
    websocket_stream_type,
)


def test_stream_names_include_websocket_backed_kline_series() -> None:
    assert kline_stream_names({"ETHUSDT", "BTCUSDT"}) == (
        "btcusdt@kline_1m",
        "btcusdt@kline_5m",
        "ethusdt@kline_1m",
        "ethusdt@kline_5m",
    )


def test_market_streams_include_all_market_ticker_and_mark_price() -> None:
    streams = market_stream_names({"BTCUSDT"})
    assert streams[-2:] == ("!ticker@arr", "!markPrice@arr@1s")


def test_streams_are_split_into_bounded_connections() -> None:
    assert chunked(("a", "b", "c", "d", "e"), 2) == (
        ("a", "b"),
        ("c", "d"),
        ("e",),
    )


def test_all_market_streams_use_a_dedicated_connection() -> None:
    shards = market_stream_shards({"ETHUSDT", "BTCUSDT"}, 2)

    assert shards == (
        ("btcusdt@kline_1m", "btcusdt@kline_5m"),
        ("ethusdt@kline_1m", "ethusdt@kline_5m"),
        MARKET_WIDE_STREAMS,
    )


def test_websocket_proxy_uses_explicit_binance_proxy_before_generic_proxy() -> None:
    assert (
        websocket_proxy(
            {
                "BINANCE_PROXY_URL": "http://binance-proxy.test:8080",
                "HTTPS_PROXY": "http://generic-proxy.test:8080",
            }
        )
        == "http://binance-proxy.test:8080"
    )
    assert websocket_proxy({}) is None


def test_websocket_connect_uses_binance_server_keepalive() -> None:
    options = websocket_connect_options("http://proxy.test:8080")

    assert options["ping_interval"] is None
    assert "ping_timeout" not in options
    assert options["proxy"] == "http://proxy.test:8080"


def test_websocket_message_context_identifies_failed_kline() -> None:
    assert websocket_message_context(
        {
            "stream": "ethusdt@kline_1m",
            "data": {"e": "kline", "k": {"s": "ETHUSDT"}},
        }
    ) == ("ethusdt@kline_1m", "ETHUSDT", "kline")


def test_websocket_log_context_classifies_shards_and_streams() -> None:
    assert websocket_shard_type(MARKET_WIDE_STREAMS) == "market_wide"
    assert websocket_shard_type(("btcusdt@kline_1m",)) == "klines"
    assert websocket_stream_type("btcusdt@kline_1m") == "kline_1m"
    assert websocket_stream_type("btcusdt@kline_5m") == "kline_5m"
    assert websocket_stream_type("!markPrice@arr@1s") == "mark_price"
    assert websocket_stream_type("!ticker@arr") == "ticker"
    assert format_message_counts({"ticker": 3, "mark_price": 5}) == (
        "mark_price:5,ticker:3"
    )
