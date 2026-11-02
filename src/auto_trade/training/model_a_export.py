from __future__ import annotations

import csv
import hashlib
import io
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime
from decimal import Decimal
from enum import Enum
from typing import Protocol, cast
from uuid import UUID

from auto_trade.training.model_a_pipeline import ModelAPipelineError

ExportScalar = str | int | bool | None
ExportValue = ExportScalar | Decimal | datetime | date | UUID | Enum
ExportRow = Mapping[str, ExportValue]


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _normalize_value(value: ExportValue) -> ExportScalar:
    if isinstance(value, datetime):
        if value.tzinfo is None or value.utcoffset() is None:
            raise ModelAPipelineError("export datetimes must be timezone-aware")
        return value.astimezone(UTC).isoformat().replace("+00:00", "Z")
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise ModelAPipelineError("export decimals must be finite")
        return format(value, "f")
    if isinstance(value, (UUID, Enum)):
        return str(value.value if isinstance(value, Enum) else value)
    return value


def _canonical_rows(rows: Sequence[ExportRow]) -> tuple[dict[str, ExportScalar], ...]:
    if not rows:
        raise ModelAPipelineError("model-A export requires at least one row")
    columns = tuple(sorted(rows[0]))
    if not columns or any(not column.strip() for column in columns):
        raise ModelAPipelineError("export columns must not be empty")
    normalized: list[dict[str, ExportScalar]] = []
    for row in rows:
        if tuple(sorted(row)) != columns:
            raise ModelAPipelineError("every exported row must have the same columns")
        normalized.append({column: _normalize_value(row[column]) for column in columns})
    return tuple(normalized)


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


class ParquetEncoder(Protocol):
    def encode(self, rows: tuple[dict[str, ExportScalar], ...]) -> bytes: ...


class PyArrowParquetEncoder:
    """Lazy optional dependency so worker-only installations stay small."""

    def encode(self, rows: tuple[dict[str, ExportScalar], ...]) -> bytes:
        try:
            import pyarrow as pa  # type: ignore[import-not-found]
            import pyarrow.parquet as pq  # type: ignore[import-not-found]
        except ImportError as error:
            raise ModelAPipelineError(
                "Parquet export requires the training-export optional dependency"
            ) from error
        sink = pa.BufferOutputStream()
        table = pa.Table.from_pylist(list(rows))
        pq.write_table(
            table,
            sink,
            compression="zstd",
            use_dictionary=False,
            write_statistics=True,
            version="2.6",
        )
        return cast(bytes, sink.getvalue().to_pybytes())


@dataclass(frozen=True, slots=True)
class ModelAExportArtifact:
    format: str
    media_type: str
    extension: str
    content: bytes
    record_count: int
    columns: tuple[str, ...]
    canonical_rows_hash: str
    content_hash: str

    def manifest(self) -> dict[str, str | int | list[str]]:
        return {
            "canonical_rows_hash": self.canonical_rows_hash,
            "columns": list(self.columns),
            "content_hash": self.content_hash,
            "format": self.format,
            "record_count": self.record_count,
            "schema_version": 1,
        }


def export_model_a_rows(
    rows: Sequence[ExportRow],
    *,
    output_format: str,
    parquet_encoder: ParquetEncoder | None = None,
) -> ModelAExportArtifact:
    normalized = _canonical_rows(rows)
    columns = tuple(normalized[0])
    canonical_rows_hash = _sha256(_canonical_json(normalized))
    if output_format == "jsonl":
        content = b"".join(_canonical_json(row) + b"\n" for row in normalized)
        media_type, extension = "application/x-ndjson", "jsonl"
    elif output_format == "csv":
        output = io.StringIO(newline="")
        writer = csv.DictWriter(output, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(normalized)
        content = output.getvalue().encode("utf-8")
        media_type, extension = "text/csv; charset=utf-8", "csv"
    elif output_format == "parquet":
        encoder = parquet_encoder or PyArrowParquetEncoder()
        content = encoder.encode(normalized)
        if not content:
            raise ModelAPipelineError("Parquet encoder returned an empty artifact")
        media_type, extension = "application/vnd.apache.parquet", "parquet"
    else:
        raise ModelAPipelineError(f"unsupported model-A export format: {output_format}")
    return ModelAExportArtifact(
        output_format,
        media_type,
        extension,
        content,
        len(normalized),
        columns,
        canonical_rows_hash,
        _sha256(content),
    )
