from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from auto_trade.training.contracts import Partition, PartitionKind
from auto_trade.training.cross_fit import CrossFitContractError, plan_cross_fit_folds


def _partition() -> Partition:
    return Partition(
        PartitionKind.TRAIN,
        datetime(2026, 1, 1, tzinfo=UTC),
        datetime(2026, 5, 1, tzinfo=UTC),
    )


def test_cross_fit_folds_are_forward_only_and_have_no_inner_validation() -> None:
    folds = plan_cross_fit_folds(
        train_partition=_partition(),
        fold_count=3,
        train_window=timedelta(days=30),
        prediction_window=timedelta(days=7),
        purge=timedelta(days=1),
        embargo=timedelta(days=1),
        warmup=timedelta(days=5),
        model_version_id=uuid4(),
        random_seed=41,
    )
    assert len(folds) == 3
    assert [fold.random_seed for fold in folds] == [41, 42, 43]
    assert all(fold.inner_validation_count == 0 for fold in folds)
    assert all(fold.effective_train_end_at <= fold.prediction_start_at for fold in folds)
    assert len({fold.fold_hash for fold in folds}) == 3


def test_cross_fit_rejects_validation_partition_and_insufficient_history() -> None:
    validation = Partition(
        PartitionKind.VALIDATION,
        datetime(2026, 1, 1, tzinfo=UTC),
        datetime(2026, 3, 1, tzinfo=UTC),
    )
    with pytest.raises(CrossFitContractError, match="TRAIN"):
        plan_cross_fit_folds(
            train_partition=validation,
            fold_count=1,
            train_window=timedelta(days=30),
            prediction_window=timedelta(days=7),
            purge=timedelta(days=1),
            embargo=timedelta(days=1),
            warmup=timedelta(days=5),
            model_version_id=uuid4(),
            random_seed=1,
        )
