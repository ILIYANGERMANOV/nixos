# Keyed sets as a union where one key holds one value: `a // b` when every key
# both hold has values `same` calls equal. Otherwise it throws `message` of the
# conflicts, each { key, left, right }, never last-writer-wins: which side comes
# last is an accident of order.
{ lib }:

same: message: a: b:
let
  conflicts = lib.concatMap (
    key:
    lib.optional (!(same a.${key} b.${key})) {
      inherit key;
      left = a.${key};
      right = b.${key};
    }
  ) (lib.attrNames (lib.intersectAttrs a b));
in
if conflicts == [ ] then a // b else throw (message conflicts)
