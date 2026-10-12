from auto_trade.collectors.websocket_klines import (
    MARKET_WIDE_STREAMS,
    chunked,
    kline_stream_names,
    market_stream_names,
    market_stream_shards,
    websocket_connect_options,
    websocket_proxy,
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
