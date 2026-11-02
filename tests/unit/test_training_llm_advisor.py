import pytest

from auto_trade.training.llm_advisor import LlmAdviceError, LlmAdvisor, TrainSummary
from auto_trade.training.optimizer import NumericParameter


class Transport:
    def __init__(self, response: str | None = None, error: Exception | None = None) -> None:
        self.response = response
        self.error = error

    async def complete(self, *, payload: str, endpoint: str) -> str:
        if self.error:
            raise self.error
        assert '"partition":"TRAIN"' in payload
        return self.response or "{}"


def summary() -> TrainSummary:
    return TrainSummary({
        "partition": "TRAIN",
        "dataset_version": "train-v1",
        "iteration_id": "iteration-1",
        "train_metrics": {"objective": 1.2},
        "search_space": {"threshold": {"minimum": 0.1, "maximum": 0.9}},
        "input_hash": "a" * 64,
    })


def test_summary_rejects_validation_and_future_fields() -> None:
    with pytest.raises(LlmAdviceError):
        TrainSummary({"partition": "VALIDATION"})
    with pytest.raises(LlmAdviceError):
        TrainSummary({"partition": "TRAIN", "future_return": 1})


def test_endpoint_must_be_https_and_allowlisted() -> None:
    with pytest.raises(LlmAdviceError):
        LlmAdvisor(Transport(), "http://allowed.example")
    with pytest.raises(LlmAdviceError):
        LlmAdvisor(Transport(), "https://not-allowed.example")


@pytest.mark.asyncio
async def test_unavailable_timeout_and_invalid_json_never_create_candidate() -> None:
    space = {"threshold": NumericParameter(0.1, 0.9)}
    unavailable = await LlmAdvisor(Transport(error=OSError()), "https://allowed.example").suggest(
        summary=summary(), search_space=space
    )
    assert unavailable.candidate is None and unavailable.status == "UNAVAILABLE"
    timeout = await LlmAdvisor(Transport(error=TimeoutError()), "https://allowed.example").suggest(
        summary=summary(), search_space=space
    )
    assert timeout.candidate is None
    invalid = await LlmAdvisor(Transport("not-json"), "https://allowed.example").suggest(
        summary=summary(), search_space=space
    )
    assert invalid.candidate is None and invalid.rejection_codes == ("INVALID_JSON",)


@pytest.mark.asyncio
async def test_response_leakage_and_candidate_range_are_rejected() -> None:
    space = {"threshold": NumericParameter(0.1, 0.9)}
    leaked = await LlmAdvisor(Transport('{"candidate":{"threshold":0.5},"validation":1}'), "https://allowed.example").suggest(
        summary=summary(), search_space=space
    )
    assert leaked.candidate is None
    out_of_range = await LlmAdvisor(Transport('{"candidate":{"threshold":2}}'), "https://allowed.example").suggest(
        summary=summary(), search_space=space
    )
    assert out_of_range.candidate is None


@pytest.mark.asyncio
async def test_valid_candidate_is_structured_and_hashed() -> None:
    result = await LlmAdvisor(Transport('{"candidate":{"threshold":0.5}}'), "https://allowed.example").suggest(
        summary=summary(), search_space={"threshold": NumericParameter(0.1, 0.9)}
    )
    assert result.status == "VALID"
    assert result.candidate == {"threshold": 0.5}
    assert result.response_hash and len(result.response_hash) == 64
