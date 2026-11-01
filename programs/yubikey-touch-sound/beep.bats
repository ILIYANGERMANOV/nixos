#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2312 # a stub's body expands when the stub runs, and a masked failure fails the assertion around it
# Only what does not depend on how long a run takes: a short interval, a bounded
# wait on each outcome, and no claim on how many times the sound played. beep
# counts whole seconds, so a window of 2 lasts between 1 and 2: 1 can last no time.

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  export afplay=afplay sound=/sounds/hero.aiff volume=6
  export interval=0.01 timeout_seconds=120
  export BEEP="$BATS_TEST_DIRNAME/beep.sh"
  # beep as a program of its own, whose EXIT outlives its own traps: orphaned, its
  # end cannot be waited on.
  stub watched-beep 'trap "touch \"\$WORK/beep-exited\"" EXIT
    set -euo pipefail
    source "$BEEP"'
}

beep() { timeout 10 bash -euo pipefail "$BEEP"; }

stops_the_sound_on() {
  stub afplay 'trap "kill \$!; touch \"\$WORK/afplay-stopped\"; exit 0" TERM
    touch "$WORK/afplay-started"
    sleep 30 &
    wait'
  watched-beep 3>&- &
  beep_pid=$!
  wait_for "$WORK/afplay-started"

  kill -"$1" "$beep_pid"

  wait_for "$WORK/afplay-stopped"
  wait "$beep_pid"
}

@test "plays the sound at the volume asked" {
  stub afplay 'echo "$*" >>"$WORK/plays"'
  timeout_seconds=2

  beep

  [ "$(head -n 1 "$WORK/plays")" = "-v 6 /sounds/hero.aiff" ]
}

@test "stops at the deadline while its parent lives" {
  stub afplay ':'
  timeout_seconds=2

  run beep

  [ "$status" -eq 0 ]
}

@test "an afplay that fails does not end the alert" {
  stub afplay 'echo played >>"$WORK/plays"; exit 1'
  timeout_seconds=2

  beep

  [ "$(wc -l <"$WORK/plays")" -ge 2 ]
}

@test "stops once its parent is gone, long before the deadline" {
  stub afplay 'touch "$WORK/played"'
  # The parent leaves after the first play, as a killed ssh does.
  stub parent 'watched-beep >/dev/null 2>&1 3>&- &
    wait_for "$WORK/played"'

  parent

  wait_for "$WORK/beep-exited"
}

@test "SIGTERM takes the sound in flight down with it and exits clean" {
  stops_the_sound_on TERM
}

@test "SIGHUP takes the sound in flight down with it and exits clean" {
  stops_the_sound_on HUP
}
