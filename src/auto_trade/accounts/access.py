from __future__ import annotations

from auto_trade.accounts.models import UserRole


def api_access_error(role: UserRole, path: str) -> tuple[int, str] | None:
    if path.startswith("/api/admin/"):
        if role is not UserRole.ADMIN:
            return 403, "仅管理员可以访问用户管理"
        return None
    if path.startswith(("/api/account/", "/api/paper-trader/")):
        return None
    if role is UserRole.NORMAL:
        return 403, "该功能仅对高级用户开放"
    return None
