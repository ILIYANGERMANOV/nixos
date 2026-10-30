---
name: android
description: How to build, test and lint Android, Kotlin and Kotlin Multiplatform projects with Gradle on this machine - the global toolchain, running Gradle in the background one build at a time, stopping the daemon, and what to do when the SDK lacks a component. Use before running any Gradle task (`./gradlew`) or touching an Android or KMP project's build.
---

# Android and Kotlin on this machine

## The toolchain is global

Every session already has it. Do not add a flake, `.envrc` or dev shell to a
repository for it, and do not install an SDK, JDK or Gradle yourself.

- JDK 17 is `java` and `$JAVA_HOME`. JDK 21 is registered with Gradle's
  toolchain detection, so a project asking for a 17 or 21 toolchain finds it.
- `$ANDROID_HOME` (and `$ANDROID_SDK_ROOT`) is a read-only SDK: platforms 35
  and 36, build-tools 35.0.0 and 36.0.0, platform-tools. No NDK, no emulator,
  no system images.
- `$GRADLE_OPTS` points AGP at the SDK's aapt2, because the one it downloads
  from Maven cannot run here. Leave it set.
- `kotlinc`, `ktlint`, `detekt`, `kotlin-lsp` and `adb` are on PATH. Gradle
  itself comes from each project's `./gradlew`.

## Running Gradle

The box has 7.7 GB of memory. `~/.gradle/gradle.properties`
runs Gradle as one 4 GB JVM with the Kotlin compiler inside it; two Gradle
daemons running lint at once have run it out of memory.

- Run every Gradle command with `run_in_background`, or as a subagent in the
  foreground with `timeout: 600000` as `timeout 590 ./gradlew ...`. A cold
  build downloads dependencies and can take well over 10 minutes. Downloads
  and finished tasks survive, so on exit 124 run `./gradlew --stop`, then the
  same command again, until it exits with anything else.
- One Gradle build at a time, across all your subagents. Never start a second
  `./gradlew` while one runs.
- Do not raise `-Xmx`, enable `org.gradle.parallel` or start a Kotlin daemon
  from the command line or a project's own properties.
- Run `./gradlew --stop` when you are done with Gradle, so the daemon gives
  its memory back now rather than after its 15-minute idle timeout.

## What cannot run here

- No device and no emulator: `connectedAndroidTest` and anything needing
  `adb devices` cannot run. Use JVM unit tests, Robolectric and screenshot
  tests (Paparazzi, Roborazzi) instead.
- No iOS: Apple targets of a KMP project need macOS. Build the Android and
  JVM targets.
- Linux native targets are unreliable: the Kotlin/Native compiler compiles
  and links, then can crash its JVM (SIGSEGV in `ffiFreeClosure0`) while
  shutting down, failing the task or killing the daemon. Prefer `jvmTest`
  and the Android unit tests; report a native failure as this known gap
  rather than debugging it.

## A missing SDK component

AGP cannot install anything into the read-only SDK, so a build asking for a
platform, build-tools version or NDK it lacks fails with a licence or "not
found" error. Do not run `sdkmanager` or point `ANDROID_HOME` elsewhere.

1. If the project pins a build-tools version that is not installed, check
   whether an installed one works; ask before changing the project's
   `compileSdk` or `buildToolsVersion`.
2. Otherwise stop and tell the person which component is missing. It is added
   to the SDK in `programs/kotlin/default.nix` of the nixos repository.
