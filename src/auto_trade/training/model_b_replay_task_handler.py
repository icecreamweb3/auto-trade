"""MODEL_B_REPLAY v1 governed task handler."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import cast

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_b_replay_repository import (
    DatabaseModelBReplayTaskStore,
    ModelBReplayContext,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease
from auto_trade.training.simulation_repository import DatabaseModelBWorkerStore
from auto_trade.training.simulation_service import FixedExitReplayService
from auto_trade.training.simulator import (
    FeeModel,
    FixedExitPolicy,
    SimulationContractError,
    SlippageModel,
    fixed_exit_policy_from_config,
)


class ModelBReplayError(SimulationContractError):
    """A MODEL_B_REPLAY payload or trusted context violates the v1 contract."""


def _sha256(payload: object) -> str:
    return hashlib.sha256(
        json.dumps(
            payload,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode()
    ).hexdigest()


def _content_id(value: object) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ModelBReplayError("model_b_sample_ids must contain lowercase SHA-256 values")
    return value


def _decimal(config: Mapping[str, object], field: str) -> Decimal:
    value = config.get(field)
    if isinstance(value, bool) or value is None:
        raise ModelBReplayError(f"trusted model-B config is missing {field}")
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError) as error:
        raise ModelBReplayError(f"trusted model-B config has invalid {field}") from error


@dataclass(frozen=True, slots=True)
class ModelBReplayTaskPayload:
    model_b_sample_ids: tuple[str, ...]


def parse_model_b_replay_payload(
    payload: Mapping[str, object],
) -> ModelBReplayTaskPayload:
    allowed = {"task_type", "payload_version", "model_b_sample_ids"}
    unexpected = sorted(set(payload) - allowed)
    if unexpected:
        raise ModelBReplayError("unexpected MODEL_B_REPLAY fields: " + ", ".join(unexpected))
    if payload.get("task_type") != "MODEL_B_REPLAY" or payload.get("payload_version") != 1:
        raise ModelBReplayError("MODEL_B_REPLAY requires payload_version 1")
    raw_ids = payload.get("model_b_sample_ids")
    if not isinstance(raw_ids, list) or not raw_ids:
        raise ModelBReplayError("model_b_sample_ids must be a non-empty array")
    sample_ids = tuple(_content_id(value) for value in cast(list[object], raw_ids))
    if sample_ids != tuple(sorted(set(sample_ids))):
        raise ModelBReplayError("model_b_sample_ids must be unique and sorted")
    return ModelBReplayTaskPayload(sample_ids)


def _policy(context: ModelBReplayContext) -> FixedExitPolicy:
    try:
        return fixed_exit_policy_from_config(context.exit_rule_version_id, context.exit_rule_config)
    except SimulationContractError as error:
        raise ModelBReplayError(f"trusted EXIT_RULES is invalid: {error}") from error


def _fee_model(context: ModelBReplayContext) -> FeeModel:
    taker_rate = _decimal(context.fee_model_config, "taker_rate")
    return FeeModel(context.fee_model_version_id, taker_rate, taker_rate)


def _slippage_model(context: ModelBReplayContext) -> SlippageModel:
    config = context.slippage_model_config
    return SlippageModel(
        context.slippage_model_version_id,
        _decimal(config, "base_basis_points"),
        _decimal(config, "notional_coefficient"),
        _decimal(config, "reference_notional"),
        _decimal(config, "liquidity_coefficient"),
        _decimal(config, "volatility_coefficient"),
        _decimal(config, "maximum_basis_points"),
    )


class ModelBReplayTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._task_store = DatabaseModelBReplayTaskStore(connection)
        self._replay_service = FixedExitReplayService(DatabaseModelBWorkerStore(connection))

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.MODEL_B:
            raise ModelBReplayError("MODEL_B_REPLAY requires MODEL_B executor")
        payload = parse_model_b_replay_payload(lease.payload)
        evidence: list[dict[str, str]] = []
        for model_b_sample_id in payload.model_b_sample_ids:
            context = await self._task_store.load_context(
                lease.task_id, lease.lease_token, model_b_sample_id
            )
            if context.episode_status == "RUNNING":
                await self._replay_service.replay(
                    model_b_sample_id=model_b_sample_id,
                    entry_event_id=context.entry_event_id,
                    notional=context.notional,
                    policy=_policy(context),
                    fee_model=_fee_model(context),
                    slippage_model=_slippage_model(context),
                )
            elif context.episode_status != "DECIDED":
                raise ModelBReplayError("model-B episode is neither RUNNING nor DECIDED")
            terminal_hash = await self._task_store.load_terminal_decision_hash(
                context.exit_episode_id
            )
            evidence.append(
                {
                    "exit_episode_id": context.exit_episode_id,
                    "model_b_sample_id": model_b_sample_id,
                    "terminal_decision_hash": terminal_hash,
                }
            )
        return _sha256({"payload_version": 1, "episodes": evidence})
