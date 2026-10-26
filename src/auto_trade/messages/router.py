from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query, Request

from auto_trade.messages.models import ChannelMessagePage, MessageChannelSummary
from auto_trade.messages.repository import MessageRepository

router = APIRouter(prefix="/api/messages", tags=["messages"])


@router.get("/channels", response_model=tuple[MessageChannelSummary, ...])
async def message_channels(request: Request) -> tuple[MessageChannelSummary, ...]:
    try:
        return await MessageRepository(request.app.state.database_engine).channels()
    except Exception as error:
        raise HTTPException(
            status_code=503,
            detail="message channels unavailable",
        ) from error


@router.get("/channels/{channel_id}", response_model=ChannelMessagePage)
async def channel_messages(
    request: Request,
    channel_id: int,
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    signal_kind: str | None = Query(default=None, max_length=32),
) -> ChannelMessagePage:
    normalized_kind = signal_kind.strip().upper() if signal_kind else None
    try:
        result = await MessageRepository(
            request.app.state.database_engine
        ).messages(
            channel_id=channel_id,
            page=page,
            page_size=page_size,
            signal_kind=normalized_kind,
        )
    except Exception as error:
        raise HTTPException(status_code=503, detail="channel messages unavailable") from error
    if result is None:
        raise HTTPException(status_code=404, detail="message channel not found")
    return result
