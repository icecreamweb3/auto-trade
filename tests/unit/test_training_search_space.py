from auto_trade.training.optimizer import NumericParameter
from auto_trade.training.search_space import VersionedSearchSpace


def test_versioned_search_space_hash_is_deterministic() -> None:
    space = VersionedSearchSpace(
        "model-b-v1",
        {"stop_loss": NumericParameter(0.01, 0.05)},
    )
    assert len(space.content_hash) == 64
    assert space.content_hash == space.content_hash
