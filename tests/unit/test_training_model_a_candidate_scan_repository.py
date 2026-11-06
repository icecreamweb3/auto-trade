from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

from auto_trade.training.model_a_candidate_scan_repository import (
    DatabaseModelACandidateScanStore,
)


async def test_random_baseline_context_selects_and_maps_reference_dataset() -> None:
    config_version_id = uuid4()
    reference_dataset_id = uuid4()
    result = MagicMock()
    result.mappings.return_value.one.return_value = {
        "random_baseline_config_version_id": config_version_id,
        "config_json": {"reference_set_id": str(uuid4())},
        "reference_dataset_version_id": reference_dataset_id,
    }
    connection = AsyncMock()
    connection.execute.return_value = result

    config = await DatabaseModelACandidateScanStore(
        connection
    ).load_random_baseline_config(uuid4(), uuid4())

    statement = str(connection.execute.await_args.args[0])
    assert "reference_dataset_version_id" in statement
    assert config.config_version_id == config_version_id
    assert config.reference_dataset_version_id == reference_dataset_id
