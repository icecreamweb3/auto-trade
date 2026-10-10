from pydantic import SecretStr

from auto_trade.config import Settings


def test_database_dsn_escapes_credentials() -> None:
    settings = Settings(
        _env_file=None,
        postgres_password=SecretStr("a/b:c@d"),
        postgres_user="collector@example",
    )
    assert "collector%40example" in settings.database_dsn
    assert "a%2Fb%3Ac%40d" in settings.database_dsn
    assert "a/b:c@d" not in settings.database_dsn
