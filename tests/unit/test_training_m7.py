from decimal import Decimal
from uuid import uuid4

import pytest

from auto_trade.training.contracts import EntrySource
from auto_trade.training.test_executor import TestExecutionError, TestExecutor
from auto_trade.training.validation_scope import ValidationBudgetError, ValidationBudgetLedger
from auto_trade.training.weak_holdout import WeakHoldoutError, WeakHoldoutRequest


def test_validation_budget_is_not_reset_by_a_new_reservation() -> None:
    ledger = ValidationBudgetLedger(1, Decimal("0.05"))
    ledger.reserve(evaluation_count=1, alpha=Decimal("0.05"))
    with pytest.raises(ValidationBudgetError):
        ledger.reserve(evaluation_count=1, alpha=Decimal("0.01"))


def test_weak_holdout_is_declared_and_never_promotable() -> None:
    request = WeakHoldoutRequest(uuid4(), uuid4(), uuid4())
    assert request.exposure_status == "DECLARED"
    with pytest.raises(WeakHoldoutError):
        WeakHoldoutRequest(uuid4(), uuid4(), uuid4(), exposure_status="NONE")


@pytest.mark.asyncio
async def test_test_executor_rejects_non_runtime_source_before_store_read() -> None:
    class Store:
        called = False

        async def consume_test_set(self, *args: object) -> object:
            self.called = True
            raise AssertionError("store must not be read")

    store = Store()
    executor = TestExecutor(store, "test-executor")
    with pytest.raises(TestExecutionError):
        await executor.consume(
            test_set_id=uuid4(), request_id=uuid4(), source=EntrySource.CROSS_FIT_MODEL_A
        )
    assert not store.called
