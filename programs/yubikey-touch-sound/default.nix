# Audible alert while the YubiKey is waiting for a physical touch (macOS).
#
# The LED is invisible in bright light, so a tap-required operation just hangs
# with no usable feedback. These wrappers make the Mac play a sound for as long
# as the token is waiting, and stop the instant you tap.
#
# Only Apple-shipped software does the talking: /usr/bin/afplay and a stock
# /System/Library/Sounds/*.aiff. No daemon, no agent, no third-party package.
#
# There are two touch paths and they need different treatment:
#
#   * SSH auth (`git push`, `ssh`) — OpenSSH has a first-class hook here:
#     sshconnect2.c:identity_sign() calls notify_start(), which forks
#     $SSH_ASKPASS with the notification as argv[1] and SIGTERMs it the moment
#     the touch lands (readpass.c). Exact timing, self-stopping. See `ssh`.
#
#   * Commit signing (`ssh-keygen -Y sign`) — no hook exists: sign_one() writes
#     "Confirm user presence..." with a bare fprintf(stderr) and git captures
#     the signer's stderr, so today nothing whatsoever reaches the terminal.
#     Handled by beeping for the duration of the call. See `sshKeygen`.
{
  pkgs,
  lib ? pkgs.lib,
  # Any stock macOS system sound. Hero is the loudest of them (-24 dBFS RMS,
  # 0.54 peak — roughly 5 dB above Submarine and on par with herdr's chime).
  sound ? "/System/Library/Sounds/Hero.aiff",
  # afplay gain. 1.0 is the file as-is; higher amplifies past the system volume,
  # which is the point — this has to cut through outdoor noise.
  volume ? "6",
  # Gap between repeats, in seconds.
  interval ? "0.7",
  # Hard ceiling on a single alert, in seconds. Matches the ~25s touch window
  # the LED flashes for: past that the operation has failed anyway, so a still-
  # sounding alert can only mean it was orphaned. See `beep`.
  timeoutSeconds ? "30",
}:

let
  shellCheck = import ../shell-check { inherit pkgs; };

  afplay = "/usr/bin/afplay";
  openssh = lib.getExe pkgs.openssh;
  opensshKeygen = lib.getExe' pkgs.openssh "ssh-keygen";

  beepSettings = {
    inherit
      afplay
      sound
      volume
      interval
      ;
    timeout_seconds = timeoutSeconds;
  };

  # Repeats the alert until killed. Kept in its own script so both entry points
  # share one implementation.
  beep = shellCheck.writeShellApplication {
    name = "yubikey-touch-beep";
    # `sleep`. Without this, writeShellApplication leaves PATH as the caller's,
    # so a shadowed `sleep` would run inside the auth path.
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${lib.toShellVars beepSettings}
      ${shellCheck.fragment ./beep.sh}
    '';
  };

  # $SSH_ASKPASS target. ssh(1) execs this with the notification text as $1,
  # stdin and stdout on /dev/null, and SIGTERMs it once the touch completes.
  askpass = shellCheck.writeShellApplication {
    name = "yubikey-touch-askpass";
    text = ''
      ${lib.toShellVars { beep = lib.getExe beep; }}
      ${shellCheck.fragment ./askpass.sh}
    '';
  };

  # Drop-in ssh for git (core.sshCommand) that turns the touch request audible.
  #
  # notify_start() only uses $SSH_ASKPASS when stderr is NOT a tty (or BatchMode
  # is on) AND DISPLAY/WAYLAND_DISPLAY is set. Hence the two adjustments below.
  # We deliberately do NOT set SSH_ASKPASS_REQUIRE=force, which would route
  # passphrase prompts through the helper even when a tty is available. Setting
  # DISPLAY still opens that door for the no-tty case, which is why the helper
  # guards on the prompt text.
  ssh = shellCheck.writeShellApplication {
    name = "yubikey-touch-ssh";
    # `cat`. Without this, writeShellApplication leaves PATH as the caller's,
    # so a shadowed `cat` would run inside the auth path.
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${lib.toShellVars {
        inherit openssh;
        askpass = lib.getExe askpass;
      }}
      ${shellCheck.fragment ./ssh.sh}
    '';
  };

  # Drop-in ssh-keygen for git (gpg.ssh.program). Signing always needs a tap and
  # has no notifier hook, so alert for the whole call. Verification and every
  # other subcommand are passed straight through, untouched and silent.
  sshKeygen = shellCheck.writeShellApplication {
    name = "yubikey-touch-ssh-keygen";
    text = ''
      ${lib.toShellVars {
        beep = lib.getExe beep;
        openssh_keygen = opensshKeygen;
      }}
      ${shellCheck.fragment ./ssh-keygen.sh}
    '';
  };
in
{
  inherit
    ssh
    sshKeygen
    ;
}
