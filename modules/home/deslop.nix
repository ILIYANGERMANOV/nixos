{
  programs.zsh.initContent = ''
    [[ -r /run/secrets/deslop-ultra-test-key ]] \
      && export DESLOP_ULTRA_TEST_KEY="$(< /run/secrets/deslop-ultra-test-key)"
    [[ -r /run/secrets/deslop-one-test-key ]] \
      && export DESLOP_ONE_TEST_KEY="$(< /run/secrets/deslop-one-test-key)"
  '';
}
