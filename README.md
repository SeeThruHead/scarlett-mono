# Scarlett Mono

A native macOS menu-bar helper that sends one Scarlett 8i6 microphone channel to both BlackHole 2ch channels. Select BlackHole 2ch under Command-Shift-5 → Options → Microphone. The resulting stereo recording contains the same voice signal in both ears.

The default source is Scarlett input 1. The menu lets you pause, choose a different input, reconnect, or quit. Your default microphone and speakers are not changed. The login agent starts the helper when you sign in; a manual quit keeps it off until the next login or launch.

## Audio path

Core Audio creates a private, temporary aggregate containing Scarlett and BlackHole. Scarlett supplies the clock; BlackHole uses drift compensation. The real-time callback reads the chosen Scarlett channel and copies it at unchanged gain to both BlackHole output channels. Other output streams are disabled. No audio is sent to the Scarlett speakers, stored, or uploaded.

A separate BlackHole input callback checks the actual resulting audio. Only numeric levels and status are written to `~/Library/Application Support/Scarlett Mono/status.json`. It reports authorization, sample rate, callback counts, left/right peaks and their maximum sample difference. Live audio requires macOS microphone permission. The helper cannot approve or bypass that permission.

Devices are checked every two seconds. The bridge reconnects after device removal/reconnection, sample-rate changes or wake. A file lock prevents duplicate instances. Real-time buffers and counters are the mutable boundary; callbacks perform no allocation, locking, logging or filesystem work.

## Build and run

Requires Apple Command Line Tools, Python 3 and pnpm. There are no downloaded runtime dependencies.

```
pnpm run build
pnpm run test
pnpm run check:layout
pnpm run install
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.shanekeulen.ScarlettMono.plist"
```

Before replacing a running install, unload it:

```
launchctl bootout gui/$(id -u)/com.shanekeulen.ScarlettMono
```

The installer replaces the app using a newly created bundle, preserving the previous installation under Application Support. It does not overwrite the executable of a running process.

Signing uses a persistent local certificate stored in a dedicated keychain under `~/Library/Application Support/Scarlett Mono/signing`. Keep that directory private and retain it across updates. The app's designated requirement includes its identifier and certificate fingerprint, so updated builds retain their identity. The certificate is trusted only for code signing on this Mac. No Apple developer account or notarization is configured. A fresh machine requires a new identity and microphone approval.

## Locations

- App: `~/Applications/Scarlett Mono.app`
- Startup: `~/Library/LaunchAgents/com.shanekeulen.ScarlettMono.plist`
- Status: `~/Library/Application Support/Scarlett Mono/status.json`
- Logs: `~/Library/Logs/Scarlett Mono/`
- Source: `~/code/scarlett-mono/`

## Verification

`pnpm run test` checks channel selection, identical stereo output, unchanged gain, bounded copies, nonfinite sample handling and missing inputs with UndefinedBehaviorSanitizer enabled. AddressSanitizer could not run on the installed macOS/toolchain combination: its runtime deadlocked before entering the test program.

`pnpm run check:layout` creates and destroys a private bridge without starting recording. It verifies the Scarlett/BlackHole channel layout. Live verification must additionally show nonzero equal left/right peaks and zero channel difference. A screen recording checks that Screenshot uses the intended input.

Physical unplug/replug and sleep/wake need manual validation. Restart and permission persistence can be checked without disconnecting hardware.

## Verified on this Mac

The corrected signed build retained microphone authorization across an app update and restart. A native Screenshot recording saved on September 15, 2026 contains 48 kHz stereo AAC, with nonzero audio and identical decoded left/right samples (maximum difference 0 over 1,524,672 checked frames). The evidence and recording are under `~/tmp/investigations/scarlett-mono/`.
