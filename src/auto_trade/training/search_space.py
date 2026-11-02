from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import cast

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
        parameters: dict[str, object] = {}
        for name, rule in self.parameters.items():
            if isinstance(rule, NumericParameter):
                parameters[name] = {
                    "kind": "numeric", "minimum": rule.minimum,
                    "maximum": rule.maximum, "integer": rule.integer,
                }
            elif isinstance(rule, CategoricalParameter):
                parameters[name] = {"kind": "categorical", "choices": rule.choices}
        values: dict[str, object] = {"version": self.version, "parameters": parameters}
        return hashlib.sha256(
            json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()


def parse_versioned_search_space(
    version: str, config: Mapping[str, object]
) -> VersionedSearchSpace:
    """Parse only explicit versioned rules; no optimizer bounds are inferred."""
    raw_parameters = config.get("parameters")
    if not isinstance(raw_parameters, Mapping) or not raw_parameters:
        raise ValueError("SEARCH_SPACE requires a non-empty parameters object")
    parsed: dict[str, ParameterRule] = {}
    for raw_name, raw_rule in sorted(raw_parameters.items(), key=lambda item: str(item[0])):
        name = str(raw_name)
        if not name.strip():
            raise ValueError("search-space parameter name cannot be blank")
        if isinstance(raw_rule, (list, tuple)):
            values = tuple(cast(list[object] | tuple[object, ...], raw_rule))
            if (
                len(values) != 2
                or isinstance(values[0], bool)
                or isinstance(values[1], bool)
                or not isinstance(values[0], (int, float))
                or not isinstance(values[1], (int, float))
            ):
                raise ValueError(f"legacy numeric rule is invalid: {name}")
            parsed[name] = NumericParameter(float(values[0]), float(values[1]))
            continue
        if not isinstance(raw_rule, Mapping):
            raise ValueError(f"parameter rule must be an object: {name}")
        kind = raw_rule.get("kind")
        if kind == "numeric":
            minimum = raw_rule.get("minimum")
            maximum = raw_rule.get("maximum")
            integer = raw_rule.get("integer", False)
            if (
                isinstance(minimum, bool)
                or isinstance(maximum, bool)
                or not isinstance(minimum, (int, float))
                or not isinstance(maximum, (int, float))
                or not isinstance(integer, bool)
            ):
                raise ValueError(f"numeric parameter rule is invalid: {name}")
            parsed[name] = NumericParameter(float(minimum), float(maximum), integer)
        elif kind == "categorical":
            choices = raw_rule.get("choices")
            if not isinstance(choices, (list, tuple)) or not choices:
                raise ValueError(f"categorical parameter rule is invalid: {name}")
            normalized = tuple(cast(list[object] | tuple[object, ...], choices))
            if any(
                not isinstance(choice, (str, int, bool)) or isinstance(choice, float)
                for choice in normalized
            ):
                raise ValueError(f"categorical choices are invalid: {name}")
            parsed[name] = CategoricalParameter(
                cast(tuple[str | int | bool, ...], normalized)
            )
        else:
            raise ValueError(f"unknown parameter rule kind: {name}")
    return VersionedSearchSpace(version, parsed)
