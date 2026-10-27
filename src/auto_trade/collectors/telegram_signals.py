from __future__ import annotations

import re
from enum import StrEnum

from pydantic import BaseModel, ConfigDict

PARSER_VERSION = "wizzalert-v1"
BWE_PARSER_VERSION = "bwe-oi-price-v1"
GENERIC_PARSER_VERSION = "telegram-generic-v1"


class TelegramSignalKind(StrEnum):
    ENTRY = "ENTRY"
    CONTINUATION = "CONTINUATION"
    REVERSAL_WARNING = "REVERSAL_WARNING"
    INVALIDATION = "INVALIDATION"
    VOLATILITY_WAKE = "VOLATILITY_WAKE"
    EXIT = "EXIT"
    UNKNOWN = "UNKNOWN"


class TelegramSignalDirection(StrEnum):
    LONG = "LONG"
    SHORT = "SHORT"
    NEUTRAL = "NEUTRAL"


class ParsedTelegramSignal(BaseModel):
    model_config = ConfigDict(frozen=True)

    parser_version: str = PARSER_VERSION
    symbol_raw: str | None = None
    symbol: str | None = None
    signal_kind: TelegramSignalKind
    direction: TelegramSignalDirection
    score: int | None = None
    action_text: str | None = None
    metrics: dict[str, float]
    is_actionable: bool = False


_HEADER_PATTERN = re.compile(
    r"^[^A-Za-z0-9\u4e00-\u9fff$]*\$?"
    r"(?P<symbol>[A-Za-z0-9\u4e00-\u9fff]{1,24})"
    r"(?:\s+#\d+)?\s+·",
)
_SCORE_PATTERN = re.compile(r"(?:^|[·\s])分\s*(?P<score>\d{1,3})(?:\D|$)")
_METRIC_PATTERNS = {
    "change_5m_percent": re.compile(r"\b5m\s*(?P<value>[+-]?\d+(?:\.\d+)?)%"),
    "change_1h_percent": re.compile(r"\b1h\s*(?P<value>[+-]?\d+(?:\.\d+)?)%"),
    "change_24h_percent": re.compile(r"(?P<value>[+-]?\d+(?:\.\d+)?)%\s*\(24h\)"),
    "volume_multiple": re.compile(
        "\\bvol\\s*(?P<value>\\d+(?:\\.\\d+)?)\\u00d7",
        re.IGNORECASE,
    ),
    "open_interest_change_percent": re.compile(
        r"\bOI\s*(?P<value>[+-]?\d+(?:\.\d+)?)%",
        re.IGNORECASE,
    ),
}
_BWE_CHINESE_PATTERN = re.compile(
    r"\[(?P<symbol>[A-Za-z0-9]{1,32})\]\s*"
    r"币安未平仓合约量\s*(?P<oi_change>[+-]?\d+(?:\.\d+)?)%\uFF0C\s*"
    r"过去\s*(?P<window_seconds>\d+)\s*秒价格(?P<price_direction>上涨|下跌)\s*"
    r"(?P<price_change>[+-]?\d+(?:\.\d+)?)%\uFF0C\s*"
    r"未平仓合约量\uFF1A\s*(?P<open_interest>[\d.]+)\s*"
    r"(?P<open_interest_unit>万|亿)?美元\uFF0C\s*"
    r"未平仓合约量/市值比率\uFF1A\s*"
    r"(?P<oi_marketcap_ratio>[+-]?\d+(?:\.\d+)?)%\uFF0C\s*"
    r"24\s*小时价格变动\uFF1A\s*(?P<change_24h>[+-]?\d+(?:\.\d+)?)%",
)
_BWE_MARKET_CAP_PATTERN = re.compile(
    r"(?P<symbol>[A-Za-z0-9]{1,32})\s+MarketCap:\s*"
    r"(?P<value>[\d.]+)\s*(?P<unit>[KMB])\b",
    re.IGNORECASE,
)


def _descriptor(lines: list[str]) -> str:
    for index, line in enumerate(lines):
        if set(line) <= {"─", "-"} and index + 1 < len(lines):
            return lines[index + 1]
    return " ".join(lines[:4])


def _signal_kind(descriptor: str) -> TelegramSignalKind:
    if "原信号失效" in descriptor:
        return TelegramSignalKind.INVALIDATION
    if "波动率苏醒" in descriptor:
        return TelegramSignalKind.VOLATILITY_WAKE
    if "反转预警" in descriptor:
        return TelegramSignalKind.REVERSAL_WARNING
    if "续涨" in descriptor or "续跌" in descriptor or "同向延续" in descriptor:
        return TelegramSignalKind.CONTINUATION
    if "入场" in descriptor or "做多" in descriptor or "做空" in descriptor:
        return TelegramSignalKind.ENTRY
    if "止盈" in descriptor or "减仓" in descriptor or "止损" in descriptor:
        return TelegramSignalKind.EXIT
    return TelegramSignalKind.UNKNOWN


def _direction(descriptor: str) -> TelegramSignalDirection:
    if "续涨" in descriptor or "做多" in descriptor or "多头侧" in descriptor:
        return TelegramSignalDirection.LONG
    if "续跌" in descriptor or "做空" in descriptor or "空头侧" in descriptor:
        return TelegramSignalDirection.SHORT
    return TelegramSignalDirection.NEUTRAL


def _action_text(lines: list[str]) -> str | None:
    for index, line in enumerate(lines):
        if line == "动作" and index + 1 < len(lines):
            return lines[index + 1]
    return None


def parse_wizzalert_message(text: str) -> ParsedTelegramSignal:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    header = lines[0] if lines else ""
    header_match = _HEADER_PATTERN.search(header)
    symbol_raw = header_match.group("symbol") if header_match else None
    symbol = None
    if symbol_raw is not None and symbol_raw.isascii() and symbol_raw.isalnum():
        normalized = symbol_raw.upper()
        symbol = normalized if normalized.endswith("USDT") else f"{normalized}USDT"

    descriptor = _descriptor(lines)
    signal_kind = _signal_kind(descriptor)
    direction = _direction(descriptor)
    score_match = _SCORE_PATTERN.search(descriptor)
    score = int(score_match.group("score")) if score_match else None
    metrics = {
        name: float(match.group("value"))
        for name, pattern in _METRIC_PATTERNS.items()
        if (match := pattern.search(text)) is not None
    }
    is_actionable = (
        signal_kind is TelegramSignalKind.ENTRY
        and direction is not TelegramSignalDirection.NEUTRAL
        and score is not None
        and score >= 50
    )
    return ParsedTelegramSignal(
        symbol_raw=symbol_raw,
        symbol=symbol,
        signal_kind=signal_kind,
        direction=direction,
        score=score,
        action_text=_action_text(lines),
        metrics=metrics,
        is_actionable=is_actionable,
    )


def _scaled_value(value: str, unit: str | None, units: dict[str, float]) -> float:
    return float(value) * units.get((unit or "").upper(), 1.0)


def bwe_chinese_display_text(text: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    chinese_line = next((line for line in lines if "🇨🇳" in line), None)
    market_cap_match = _BWE_MARKET_CAP_PATTERN.search(text)
    display_lines = [chinese_line] if chinese_line is not None else []
    if market_cap_match is not None:
        market_cap = _scaled_value(
            market_cap_match.group("value"),
            market_cap_match.group("unit"),
            {"K": 1_000.0, "M": 1_000_000.0, "B": 1_000_000_000.0},
        )
        display_lines.extend(
            [
                "💰 市值",
                f"{market_cap_match.group('symbol').upper()} 市值\uFF1A"
                f"{market_cap / 10_000:g} 万美元",
            ]
        )
    if display_lines:
        return "\n".join(display_lines)
    return "\n".join(line for line in lines if re.search(r"[\u4e00-\u9fff]", line))


def parse_bwe_oi_price_message(text: str) -> ParsedTelegramSignal:
    match = _BWE_CHINESE_PATTERN.search(text)
    if match is None:
        return ParsedTelegramSignal(
            parser_version=BWE_PARSER_VERSION,
            signal_kind=TelegramSignalKind.UNKNOWN,
            direction=TelegramSignalDirection.NEUTRAL,
            metrics={},
        )
    symbol_raw = match.group("symbol").upper()
    symbol = symbol_raw if symbol_raw.endswith("USDT") else f"{symbol_raw}USDT"
    price_change = abs(float(match.group("price_change")))
    if match.group("price_direction") == "下跌":
        price_change = -price_change
    open_interest_usd = _scaled_value(
        match.group("open_interest"),
        match.group("open_interest_unit"),
        {"万": 10_000.0, "亿": 100_000_000.0},
    )
    metrics = {
        "open_interest_change_percent": float(match.group("oi_change")),
        "price_change_percent": price_change,
        "window_seconds": float(match.group("window_seconds")),
        "open_interest_usd": open_interest_usd,
        "oi_marketcap_ratio_percent": float(match.group("oi_marketcap_ratio")),
        "change_24h_percent": float(match.group("change_24h")),
    }
    market_cap_match = _BWE_MARKET_CAP_PATTERN.search(text)
    if market_cap_match is not None:
        metrics["market_cap_usd"] = _scaled_value(
            market_cap_match.group("value"),
            market_cap_match.group("unit"),
            {"K": 1_000.0, "M": 1_000_000.0, "B": 1_000_000_000.0},
        )
    direction = (
        TelegramSignalDirection.LONG
        if price_change > 0
        else TelegramSignalDirection.SHORT
        if price_change < 0
        else TelegramSignalDirection.NEUTRAL
    )
    return ParsedTelegramSignal(
        parser_version=BWE_PARSER_VERSION,
        symbol_raw=symbol_raw,
        symbol=symbol,
        signal_kind=TelegramSignalKind.VOLATILITY_WAKE,
        direction=direction,
        metrics=metrics,
        is_actionable=False,
    )


def telegram_display_text(channel: str, text: str) -> str:
    if channel.lower().lstrip("@") == "bwe_oi_price_monitor":
        return bwe_chinese_display_text(text)
    return text


def parse_telegram_message(channel: str, text: str) -> ParsedTelegramSignal:
    normalized = channel.lower().lstrip("@")
    if normalized == "wizzalert":
        return parse_wizzalert_message(text)
    if normalized == "bwe_oi_price_monitor":
        return parse_bwe_oi_price_message(text)
    return ParsedTelegramSignal(
        parser_version=GENERIC_PARSER_VERSION,
        signal_kind=TelegramSignalKind.UNKNOWN,
        direction=TelegramSignalDirection.NEUTRAL,
        metrics={},
    )
