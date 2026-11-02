from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from uuid import UUID


class PromotionError(ValueError):
    """A TEST evidence or shadow export request violates promotion policy."""


def build_test_evidence_hash(
    *,
    test_set_id: UUID,
    consumption_chain_id: UUID,
    dataset_version_id: UUID,
    model_version_ids: tuple[UUID, ...],
    result_manifest_hash: str,
) -> str:
    if len(result_manifest_hash) != 64 or any(
        c not in "0123456789abcdef" for c in result_manifest_hash
    ):
        raise PromotionError("result manifest hash must be lowercase SHA-256")
    payload = {
        "consumption_chain_id": str(consumption_chain_id),
        "dataset_version_id": str(dataset_version_id),
        "model_version_ids": sorted(str(value) for value in model_version_ids),
        "result_manifest_hash": result_manifest_hash,
        "test_set_id": str(test_set_id),
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


@dataclass(frozen=True, slots=True)
class ShadowExportRequest:
    model_version_id: UUID
    test_evidence_hash: str
    requested_by_user_id: UUID
    destination: str = "SHADOW"

    def __post_init__(self) -> None:
        if self.destination != "SHADOW":
            raise PromotionError("M9 can only create SHADOW exports")
        if len(self.test_evidence_hash) != 64 or any(
            c not in "0123456789abcdef" for c in self.test_evidence_hash
        ):
            raise PromotionError("test evidence hash must be lowercase SHA-256")


def assert_no_live_promotion(destination: str) -> None:
    if destination.upper() not in {"SHADOW", "SHADOW_EXPORT"}:
        raise PromotionError("automatic live trading promotion is forbidden")
