from datetime import timedelta

from auto_trade.infrastructure.nats_streams import GIB, STREAMS


def test_stream_subjects_do_not_overlap() -> None:
    roots = [definition.subjects[0].removesuffix(">") for definition in STREAMS]
    assert len(roots) == len(set(roots))


def test_retention_windows_match_data_criticality() -> None:
    windows = {definition.name: definition.max_age for definition in STREAMS}
    assert windows["RAW_MARKET"] == timedelta(hours=72)
    assert windows["NORMALIZED_MARKET"] == timedelta(days=7)
    assert windows["DECISIONS"] == timedelta(days=30)
    assert windows["TRADE_EVENTS"] == timedelta(days=30)
    assert windows["DLQ"] == timedelta(days=30)


def test_stream_file_limits_leave_server_headroom() -> None:
    limits = {definition.name: definition.max_bytes for definition in STREAMS}
    assert limits == {
        "RAW_MARKET": 10 * GIB,
        "NORMALIZED_MARKET": 40 * GIB,
        "DECISIONS": 6 * GIB,
        "TRADE_EVENTS": 4 * GIB,
        "DLQ": 2 * GIB,
    }
    assert sum(limits.values()) == 62 * GIB


def test_stream_configs_apply_file_limits() -> None:
    for definition in STREAMS:
        assert definition.config().max_bytes == definition.max_bytes
