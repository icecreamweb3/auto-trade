from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Cookie, Depends, HTTPException, Query, Request, Response

from auto_trade.accounts.models import (
    AccountTradeHistory,
    AdminUser,
    Credentials,
    CurrentUser,
    LoginCredentials,
    PaperTraderPreferences,
    UserRole,
    UserRoleUpdate,
)
from auto_trade.accounts.repository import (
    AccountRepository,
    EmailAlreadyRegisteredError,
)
from auto_trade.accounts.security import (
    hash_password,
    new_session_token,
    session_token_hash,
    verify_password,
)
from auto_trade.config import get_settings

AUTH_COOKIE = "auto_trade_session"
router = APIRouter(tags=["accounts"])
logger = logging.getLogger(__name__)


def _repository(request: Request) -> AccountRepository:
    return AccountRepository(request.app.state.database_engine)


async def require_user(
    request: Request,
    auto_trade_session: str | None = Cookie(default=None),
) -> CurrentUser:
    state_user = getattr(request.state, "current_user", None)
    if isinstance(state_user, CurrentUser):
        return state_user
    if not auto_trade_session:
        raise HTTPException(status_code=401, detail="请先登录")
    user = await _repository(request).current_user(session_token_hash(auto_trade_session))
    if user is None:
        raise HTTPException(status_code=401, detail="登录已过期, 请重新登录")
    return user


AuthenticatedUser = Annotated[CurrentUser, Depends(require_user)]


async def require_admin(user: AuthenticatedUser) -> CurrentUser:
    if user.role is not UserRole.ADMIN:
        raise HTTPException(status_code=403, detail="仅管理员可以执行此操作")
    return user


Administrator = Annotated[CurrentUser, Depends(require_admin)]


async def _issue_session(
    request: Request, response: Response, user_id: UUID
) -> None:
    settings = get_settings()
    token = new_session_token()
    max_age = settings.auth_session_days * 24 * 60 * 60
    await _repository(request).create_session(
        user_id,
        session_token_hash(token),
        datetime.now(UTC) + timedelta(seconds=max_age),
    )
    response.set_cookie(
        AUTH_COOKIE,
        token,
        max_age=max_age,
        httponly=True,
        secure=settings.auth_cookie_secure,
        samesite="lax",
        path="/",
    )


@router.post("/api/auth/register", response_model=CurrentUser, status_code=201)
async def register(
    payload: Credentials, request: Request, response: Response
) -> CurrentUser:
    password_hash = await asyncio.to_thread(hash_password, payload.password)
    try:
        user = await _repository(request).register(payload.email, password_hash)
    except EmailAlreadyRegisteredError as error:
        raise HTTPException(status_code=409, detail="该邮箱已经注册") from error
    await _issue_session(request, response, user.user_id)
    return user


@router.post("/api/auth/login", response_model=CurrentUser)
async def login(
    payload: LoginCredentials, request: Request, response: Response
) -> CurrentUser:
    repository = _repository(request)
    credentials = await repository.credentials(payload.identifier)
    if credentials is None:
        await asyncio.to_thread(hash_password, payload.password)
        raise HTTPException(status_code=401, detail="邮箱或密码错误")
    valid = await asyncio.to_thread(
        verify_password, payload.password, credentials["password_hash"]
    )
    if not valid:
        raise HTTPException(status_code=401, detail="邮箱或密码错误")
    user_id = credentials["user_id"]
    await _issue_session(request, response, user_id)
    user = await repository.current_user_for_id(user_id)
    return user


@router.post("/api/auth/logout", status_code=204)
async def logout(
    request: Request,
    response: Response,
    auto_trade_session: str | None = Cookie(default=None),
) -> None:
    if auto_trade_session:
        await _repository(request).delete_session(session_token_hash(auto_trade_session))
    response.delete_cookie(AUTH_COOKIE, path="/", httponly=True, samesite="lax")


@router.get("/api/auth/me", response_model=CurrentUser)
async def me(user: AuthenticatedUser) -> CurrentUser:
    return user


@router.get("/api/account/trades", response_model=AccountTradeHistory)
async def trade_history(
    request: Request,
    user: AuthenticatedUser,
    limit: int = Query(default=100, ge=1, le=500),
) -> AccountTradeHistory:
    repository = _repository(request)
    return AccountTradeHistory(
        account=await repository.account_summary(user.user_id),
        trades=await repository.trades(user.user_id, limit),
    )


@router.get(
    "/api/account/preferences/paper-trader",
    response_model=PaperTraderPreferences,
)
async def paper_trader_preferences(
    request: Request, user: AuthenticatedUser
) -> PaperTraderPreferences:
    try:
        return await _repository(request).paper_trader_preferences(user.user_id)
    except Exception as error:
        logger.exception("paper trader preferences lookup failed user_id=%s", user.user_id)
        raise HTTPException(status_code=503, detail="交易偏好暂时不可用") from error


@router.put(
    "/api/account/preferences/paper-trader",
    response_model=PaperTraderPreferences,
)
async def save_paper_trader_preferences(
    payload: PaperTraderPreferences,
    request: Request,
    user: AuthenticatedUser,
) -> PaperTraderPreferences:
    try:
        return await _repository(request).save_paper_trader_preferences(
            user.user_id, payload
        )
    except Exception as error:
        logger.exception("paper trader preferences save failed user_id=%s", user.user_id)
        raise HTTPException(status_code=503, detail="交易偏好暂时无法保存") from error


@router.get("/api/admin/users", response_model=tuple[AdminUser, ...])
async def list_users(
    request: Request, _administrator: Administrator
) -> tuple[AdminUser, ...]:
    return await _repository(request).users()


@router.patch("/api/admin/users/{user_id}/role", response_model=AdminUser)
async def update_user_role(
    user_id: UUID,
    payload: UserRoleUpdate,
    request: Request,
    _administrator: Administrator,
) -> AdminUser:
    if payload.role not in (UserRole.NORMAL, UserRole.ADVANCED):
        raise HTTPException(status_code=422, detail="只能设置普通用户或高级用户")
    user = await _repository(request).update_user_role(user_id, payload.role)
    if user is None:
        raise HTTPException(status_code=404, detail="用户不存在或管理员等级不可修改")
    return user
