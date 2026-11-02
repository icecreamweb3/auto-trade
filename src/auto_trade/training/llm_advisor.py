from __future__ import annotations

import asyncio
import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol
from urllib.parse import urlparse

from auto_trade.training.optimizer import CandidateStatus, ParameterRule, validate_candidate


class LlmAdviceError(ValueError):
    """A model-advisor request violated the TRAIN-only payload contract."""


_FORBIDDEN_TERMS = frozenset(
    {"validation", "test", "future", "label", "outcome", "mfe", "mae", "return", "pnl"}
)
_ALLOWED_SUMMARY_FIELDS = frozenset(
    {"partition", "dataset_version", "iteration_id", "train_metrics", "search_space", "input_hash"}
)


def _tokens(value: object) -> set[str]:
    if isinstance(value, Mapping):
        return {str(key).lower() for key in value} | {
            token for child in value.values() for token in _tokens(child)
        }
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return {token for child in value for token in _tokens(child)}
    return {str(value).lower()} if isinstance(value, str) else set()


def _assert_train_payload(payload: Mapping[str, object]) -> None:
    unknown = set(payload) - _ALLOWED_SUMMARY_FIELDS
    if unknown:
        raise LlmAdviceError(f"summary fields are not allowlisted: {sorted(unknown)}")
    if payload.get("partition") != "TRAIN":
        raise LlmAdviceError("LLM gateway accepts TRAIN summaries only")
    forbidden = sorted(_FORBIDDEN_TERMS & _tokens(payload))
    if forbidden:
        raise LlmAdviceError(f"forbidden leakage tokens: {forbidden}")


@dataclass(frozen=True, slots=True)
class TrainSummary:
    values: Mapping[str, object]

    def __post_init__(self) -> None:
        _assert_train_payload(self.values)

    @property
    def content_hash(self) -> str:
        encoded = json.dumps(self.values, sort_keys=True, separators=(",", ":"), default=str)
        return hashlib.sha256(encoded.encode()).hexdigest()


class LlmTransport(Protocol):
    async def complete(self, *, payload: str, endpoint: str) -> str: ...


@dataclass(frozen=True, slots=True)
class LlmAdviceResult:
    status: str
    candidate: Mapping[str, object] | None
    rejection_codes: tuple[str, ...]
    response_hash: str | None = None


@dataclass(frozen=True, slots=True)
class LlmAdvisor:
    transport: LlmTransport
    endpoint: str
    timeout_seconds: float = 30.0
    allowed_hosts: tuple[str, ...] = ("allowed.example",)

    def __post_init__(self) -> None:
        parsed = urlparse(self.endpoint)
        if parsed.scheme != "https" or not parsed.hostname:
            raise LlmAdviceError("LLM endpoint must use HTTPS")
        if parsed.hostname.lower() not in {host.lower() for host in self.allowed_hosts}:
            raise LlmAdviceError("LLM endpoint is outside the outbound allowlist")
        if self.timeout_seconds <= 0:
            raise LlmAdviceError("LLM timeout must be positive")

    async def suggest(
        self,
        *,
        summary: TrainSummary,
        search_space: Mapping[str, ParameterRule],
    ) -> LlmAdviceResult:
        request = json.dumps(summary.values, sort_keys=True, separators=(",", ":"), default=str)
        try:
            raw = await asyncio.wait_for(
                self.transport.complete(payload=request, endpoint=self.endpoint),
                timeout=self.timeout_seconds,
            )
        except (TimeoutError, OSError, RuntimeError):
            return LlmAdviceResult("UNAVAILABLE", None, ("LLM_UNAVAILABLE",))
        try:
            response = json.loads(raw)
        except (TypeError, json.JSONDecodeError):
            return LlmAdviceResult("REJECTED", None, ("INVALID_JSON",))
        if not isinstance(response, Mapping):
            return LlmAdviceResult("REJECTED", None, ("INVALID_RESPONSE_SHAPE",))
        if _FORBIDDEN_TERMS & _tokens(response):
            return LlmAdviceResult("REJECTED", None, ("FORBIDDEN_RESULT_FIELD",))
        candidate = response.get("candidate")
        if not isinstance(candidate, Mapping):
            return LlmAdviceResult("REJECTED", None, ("MISSING_CANDIDATE",))
        validation = validate_candidate(candidate, search_space)
        if validation.status is CandidateStatus.REJECTED:
            return LlmAdviceResult("REJECTED", None, validation.rejection_codes)
        response_hash = hashlib.sha256(raw.encode()).hexdigest()
        return LlmAdviceResult("VALID", dict(candidate), (), response_hash)
