# Handy (https://github.com/cjpais/Handy): push-to-talk dictation with a local
# Whisper model. The app itself is a Homebrew cask (modules/macos/common.nix);
# this holds what Nix presets for it.
{ pkgs }:

let
  shellCheck = import ../shell-check { inherit pkgs; };
  keyedJsonUpdate = import ../keyed-json { inherit pkgs; };

  # The keys Nix owns inside settings_store.json's `settings` object. Field
  # names and values follow Handy v0.10.1's src-tauri/src/settings.rs.
  settings = pkgs.writeText "handy-settings.json" (
    builtins.toJSON {
      # All five fields: a binding missing one fails to parse, and Handy
      # resets the whole `bindings` key to its default.
      bindings.transcribe = {
        id = "transcribe";
        name = "Transcribe";
        description = "Converts your speech into text.";
        default_binding = "option+space";
        # A lone modifier sends nothing to the focused app, unlike
        # Option+Space, which Ghostty passes on as Meta-Space.
        current_binding = "option_right";
      };
      shortcut_activation = "push_to_talk";
      selected_model = "whisper-large-v3-turbo";
      selected_language = "en";
      translate_to_english = false;
      # Words Whisper mishears, fed to it as vocabulary.
      custom_words = [
        "prose"
        "Claude Code"
        "NixOS"
        "Nix"
        "nix-darwin"
        "flake"
        "Home Manager"
        "Neovim"
        "Ghostty"
        "GitHub"
        "Haskell"
        "Kotlin"
        "subagent"
        "Handy"
        "repo"
      ];
      start_hidden = true;
      autostart_enabled = true;
      audio_feedback = true;
    }
  );
in
{
  # Handy never downloads a model on its own and clears `selected_model` when
  # its file is missing, so the file is preset under the name Handy's catalog
  # gives it.
  model = pkgs.fetchurl {
    name = "whisper-large-v3-turbo-Q8_0.gguf";
    url = "https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf/resolve/5eaf945c7978e564bae5b28a5b1639dd93c2bfb1/whisper-large-v3-turbo-Q8_0.gguf";
    sha256 = "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183";
  };

  apply = shellCheck.writeShellApplication {
    name = "handy-apply-settings";
    runtimeInputs = [ keyedJsonUpdate ];
    text = ''
      ${pkgs.lib.toShellVars { nix_settings = settings; }}
      ${shellCheck.fragment ./apply.sh}
    '';
  };
}
