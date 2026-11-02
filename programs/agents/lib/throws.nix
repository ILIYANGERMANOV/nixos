# For a check: whether forcing `value` all the way down throws.
value: !(builtins.tryEval (builtins.deepSeq value value)).success
