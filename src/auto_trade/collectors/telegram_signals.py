from __future__ import annotations

import re
from enum import StrEnum

from pydantic import BaseModel, ConfigDict

PARSER_VERSION = "wizzalert-v1"


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
