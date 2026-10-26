from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict


class MessageChannelSummary(BaseModel):
    model_config = ConfigDict(frozen=True, from_attributes=True)

    channel_id: int
    username: str
    title: str
    history_complete: bool
    message_count: int
    earliest_message_at: datetime | None = None
    latest_message_at: datetime | None = None
    last_realtime_at: datetime | None = None


class ChannelMessage(BaseModel):
    model_config = ConfigDict(frozen=True, from_attributes=True)

    channel_id: int
    message_id: int
    title: str
    posted_at: datetime
    edited_at: datetime | None = None
    message_text: str
    media_type: str | None = None
    symbol: str | None = None
    signal_kind: str | None = None
    direction: str | None = None
    score: int | None = None
    change_24h_percent: float | None = None
    is_actionable: bool = False


class ChannelMessagePage(BaseModel):
    model_config = ConfigDict(frozen=True)

    channel: MessageChannelSummary
    page: int
    page_size: int
    total: int
    signal_kind: str | None = None
    items: tuple[ChannelMessage, ...] = ()
