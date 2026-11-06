"""The model's queries: a knob reads as its default until it is set, and a
review's Not met requirements are the ones its verdicts name not-met."""

from hypothesis import given
from hypothesis import strategies as st

from state.model import (
    MODES,
    S0,
    SIZES,
    Mode,
    SizeName,
    State,
    Verdict,
    mode_of,
    not_met,
    size_of,
)


def test_an_unset_knob_reads_as_its_default() -> None:
    assert (mode_of(S0), size_of(S0)) == ("Balanced", "Normal")


@given(st.sampled_from(MODES), st.sampled_from(SIZES))
def test_a_set_knob_reads_as_itself(quality: Mode, size: SizeName) -> None:
    state = State(quality=quality, size=size)

    assert (mode_of(state), size_of(state)) == (quality, size)


def test_not_met_keeps_only_the_not_met_requirements_in_order() -> None:
    verdicts = (
        Verdict("AC1", "met"),
        Verdict("AC2", "not-met"),
        Verdict("AC3", "unverified"),
        Verdict("AC4", "not-met"),
    )

    assert not_met(verdicts) == ("AC2", "AC4")
