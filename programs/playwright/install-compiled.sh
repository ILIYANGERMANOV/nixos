# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
runHook preInstall
modules="$out/lib/node_modules"
mkdir -p "$out/lib" "$check"
mv node_modules "$modules"
ln -s "$playwright" "$modules/playwright"
mv dist/kit "$modules/qa-kit"
mv dist/wallet "$modules/qa-wallet"
echo '{"type":"module","main":"index.js"}' | tee "$modules/qa-kit/package.json" "$modules/qa-wallet/package.json" >"$check/package.json"
mv dist/qa-check*.js "$check/"
ln -s "$modules" "$check/node_modules"
runHook postInstall
