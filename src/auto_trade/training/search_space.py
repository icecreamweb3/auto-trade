from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass

from auto_trade.training.optimizer import CategoricalParameter, NumericParameter, ParameterRule


@dataclass(frozen=True, slots=True)
class VersionedSearchSpace:
    version: str
    parameters: Mapping[str, ParameterRule]

    def __post_init__(self) -> None:
        if not self.version.strip() or not self.parameters:
            raise ValueError("search-space version and parameters are required")
        if tuple(sorted(self.parameters)) != tuple(self.parameters):
            raise ValueError("search-space parameter names must be sorted")

    @property
    def content_hash(self) -> str:
        values: dict[str, object] = {"version": self.version, "parameters": {}}
        for name, rule in self.parameters.items():
            if isinstance(rule, NumericParameter):
                values["parameters"][name] = {
                    "kind": "numeric", "minimum": rule.minimum,
                    "maximum": rule.maximum, "integer": rule.integer,
                }
            elif isinstance(rule, CategoricalParameter):
                values["parameters"][name] = {"kind": "categorical", "choices": rule.choices}
        return hashlib.sha256(
            json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
