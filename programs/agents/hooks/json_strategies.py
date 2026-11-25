"""Hypothesis strategies for JSON, as hooks and backends exchange it: every
test of the hook contract and of a backend's adapter draws from these."""

from agent_hook import Json, JsonObject
from hypothesis import strategies as st

json_values: st.SearchStrategy[Json] = st.recursive(
    st.none() | st.booleans() | st.integers() | st.text(),
    lambda children: (
        st.lists(children, max_size=3)
        | st.dictionaries(st.text(), children, max_size=3)
    ),
    max_leaves=8,
)
json_objects: st.SearchStrategy[JsonObject] = st.dictionaries(
    st.text(), json_values, max_size=3
)
