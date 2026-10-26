from __future__ import annotations

import asyncio
import getpass
from pathlib import Path
from typing import Any

import qrcode  # type: ignore[import-untyped]
from telethon.errors import SessionPasswordNeededError  # type: ignore[import-untyped]

from auto_trade.collectors.telegram_client import (
    build_telegram_client,
    protect_session_file,
)
from auto_trade.config import get_settings


def _display_qr(value: str) -> None:
    code = qrcode.QRCode(border=1)
    code.add_data(value)
    code.make(fit=True)
    code.print_ascii(invert=True)


async def _complete_password(client: Any) -> None:
    password = await asyncio.to_thread(
        getpass.getpass,
        "请输入 Telegram 两步验证密码: ",
    )
    await client.sign_in(password=password)


async def _authorize_by_qr(client: Any) -> None:
    login = await client.qr_login()
    print("请在手机 Telegram 打开 设置 > 设备 > 连接桌面设备, 然后扫描下方二维码:")
    _display_qr(login.url)
    print("二维码约两分钟内有效, 正在等待手机确认……")
    try:
        await login.wait(timeout=120)
    except SessionPasswordNeededError:
        await _complete_password(client)


async def _authorize_by_phone(client: Any, phone: str) -> None:
    sent = await client.send_code_request(phone)
    delivery = type(sent.type).__name__.removeprefix("SentCodeType")
    next_type = (
        type(sent.next_type).__name__.removeprefix("CodeType")
        if sent.next_type is not None
        else "none"
    )
    print(
        "Telegram 已接受验证码请求 "
        f"delivery={delivery} next={next_type} timeout={sent.timeout or 'unknown'}s"
    )
    print("若 delivery=App, 请在其他已登录设备中查找 Telegram 官方服务消息。")
    code = await asyncio.to_thread(
        getpass.getpass,
        "请输入收到的验证码(输入时不会显示): ",
    )
    try:
        await client.sign_in(
            phone=phone,
            code=code,
            phone_code_hash=sent.phone_code_hash,
        )
    except SessionPasswordNeededError:
        await _complete_password(client)


async def authorize() -> None:
    settings = get_settings()
    if settings.telegram_phone is None:
        raise RuntimeError("TELEGRAM_PHONE is required for initial authorization")
    client = build_telegram_client(settings)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            mode = await asyncio.to_thread(
                input,
                "授权方式: [1] 二维码(推荐) [2] 手机验证码, 直接回车选择 1: ",
            )
            mode = mode.strip()
            if mode == "2":
                await _authorize_by_phone(
                    client,
                    settings.telegram_phone.get_secret_value(),
                )
            else:
                await _authorize_by_qr(client)
        entity = await client.get_entity(settings.telegram_channel)
        latest = await client.get_messages(entity, limit=1)
        print(
            "Telegram authorization succeeded "
            f"channel=@{getattr(entity, 'username', settings.telegram_channel)} "
            f"latest_message_id={latest[0].id if latest else 'none'}"
        )
    finally:
        await client.disconnect()
        protect_session_file(settings)
        parent = Path(settings.telegram_session_path).parent
        if parent.exists():
            parent.chmod(0o700)


def main() -> None:
    asyncio.run(authorize())


if __name__ == "__main__":
    main()
