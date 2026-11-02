from uuid import uuid4

import pytest

from auto_trade.training.promotion import (
    PromotionError,
    ShadowExportRequest,
    assert_no_live_promotion,
    build_test_evidence_hash,
)


def test_test_evidence_hash_is_deterministic_and_order_independent() -> None:
    args = {
        "test_set_id": uuid4(),
        "consumption_chain_id": uuid4(),
        "dataset_version_id": uuid4(),
        "model_version_ids": (uuid4(), uuid4()),
        "result_manifest_hash": "a" * 64,
    }
    first = build_test_evidence_hash(**args)
    second = build_test_evidence_hash(
        **{**args, "model_version_ids": tuple(reversed(args["model_version_ids"]))}
    )
    assert first == second


def test_shadow_export_cannot_target_live_trading() -> None:
    with pytest.raises(PromotionError):
        assert_no_live_promotion("LIVE")
    request = ShadowExportRequest(uuid4(), "b" * 64, uuid4())
    assert request.destination == "SHADOW"
    with pytest.raises(PromotionError):
        ShadowExportRequest(uuid4(), "bad", uuid4())
