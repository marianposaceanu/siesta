# siesta

Stops Colima VMs that nobody is using. Nothing stays resident: launchd runs `siesta check` once an hour, the binary looks at each profile for well under a second, stops the ones that have been idle long enough, and exits. The same binary is the CLI for status and logs.

## Why

A Colima guest keeps every page it has ever touched. Linux fills its memory with file cache from image pulls and builds, and macOS then carries that as compressed and swapped memory for as long as the VM runs. A 6 GiB profile with no containers running held 5.1 GB out of RAM on a 16 GB MacBook Air. Lima attaches a virtio balloon to the guest but never resizes it, so there is no way to hand that memory back while the VM runs. Stopping it is the only lever, and `colima start` brings it back in about twenty seconds.

## What counts as idle

A running profile is busy if any of these hold, each one switchable in the config:

- a container is running (`docker ps` over the profile's own socket)
- any process other than Lima's own plumbing holds the docker or containerd socket open: a `docker` command, compose, an IDE, a build
- an interactive `colima ssh` session is open
- optionally, the guest's 1-minute load average is above a threshold (one ssh round trip per check, off by default)

Otherwise it is idle. The first idle observation starts a clock; when a later check finds it still idle and the clock has passed `idleMinutes`, the profile is stopped. Any busy observation resets the clock. With the defaults, one check an hour and sixty idle minutes, a profile stops after one to two hours of real idleness.

## Install

```sh
make build          # swift build -c release
make test           # swift run selftest
make install        # copies to ~/.local/bin/siesta, writes the plist, loads the agent
```

Or from the tap:

```sh
brew tap marianposaceanu/tap
brew install siesta
siesta install     # loads the agent for the Homebrew binary
```

`make install` is `siesta install`, which does three things:

| What | Where |
| --- | --- |
| binary | the one `siesta install` ran from; a package build is copied to `~/.local/bin/siesta` first |
| config, written once with defaults | `~/.config/siesta/config.json` |
| launchd agent | `~/Library/LaunchAgents/com.marianposaceanu.siesta.plist`, loaded into `gui/<uid>` |

The agent follows the usual rules for a user agent on macOS: reverse-DNS label, absolute program path, explicit `PATH` because launchd gives agents almost none, `ProcessType` Background with `Nice` 10 and low-priority I/O, stdout and stderr to `~/Library/Logs/siesta/launchd.log`, `StartInterval` for the hourly run, `RunAtLoad` so the first check happens at login. State lives in `~/Library/Application Support/siesta/state.json`, the log in `~/Library/Logs/siesta/siesta.log` with rotation at 1 MiB, and every event is also sent to the unified log under subsystem `com.marianposaceanu.siesta`. No sudo anywhere. Overlapping runs are prevented with a file lock.

## Use

```
siesta status                   profiles, live counts, idle clock, agent state
siesta logs [-n N] [-f]         tail the log
siesta check [--dry-run] [-v]   one pass by hand; --dry-run never stops anything
siesta stop [profile ...]       stop now
siesta pause 2h | 45m | off     hold off automatic stops, for a long QA session
siesta run-now                  ask launchd to run a check immediately
siesta config [--init]          show or create the config file
siesta doctor                   tools, plist, agent
siesta uninstall [--purge]      unload the agent; --purge also removes binary, config, state, logs
```

Example status before the agent is installed, with the profile running and nothing using it:

```
profile      pr-qa  running  6.0 GiB, 2 cpus
live         containers 0, clients 0, ssh 0
idle         no, or not observed yet
last stop    never, 0 total
agent        not installed (run `siesta install`)
config       ~/.config/siesta/config.json (defaults)
log          ~/Library/Logs/siesta/siesta.log
```

A probe that fails, for example `docker` not answering, shows as `?` and the check reports the profile as unknown rather than idle; nothing is ever stopped on an incomplete observation. The idle clock is tied to Lima's boot session, so a profile you stop and start yourself between two checks begins from zero.

The agent also appears in System Settings > General > Login Items & Extensions under "Allow in the Background". If it is switched off there, `siesta status` says so; `launchctl enable` cannot override that switch, only the Settings pane can.

## Config

`~/.config/siesta/config.json`, every key optional:

```json
{
  "profiles": [],
  "idleMinutes": 60,
  "checkIntervalSeconds": 3600,
  "runningContainersMeanBusy": true,
  "dockerClientsMeanBusy": true,
  "sshSessionsMeanBusy": true,
  "guestLoadThreshold": null,
  "stopTimeoutSeconds": 120,
  "binPaths": ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "/usr/bin", "/bin"]
}
```

An empty `profiles` list means every profile `colima list` reports. Changing `checkIntervalSeconds` needs `siesta install` again to rewrite the plist.

## Layout

```
Sources/SiestaCore
  Paths           every file siesta touches, macOS conventions
  Config          user settings, with the probe switches
  State           persisted idle clocks; StateStore protocol, FileStateStore
  Policy          the pure decision: Facts + Config + clock -> Decision
  Backend         VMBackend protocol, ProfileInfo, errors
  ColimaBackend   the probes: colima list, docker ps, lsof, ps, ha.pid, colima stop
  Checker         one pass over the watched profiles, under a file lock
  LaunchAgent     plist, bootstrap, bootout, kickstart, status
  Shell           CommandRunner protocol; bounded subprocess with a watchdog
  Log             Logging protocol; FileLogger with rotation and the unified log, MemoryLogger
  JSONFile        one encoder and decoder for every JSON file
  Format          bytes, timestamps, durations
Sources/siesta
  main            builds the Context, dispatches by name, maps errors to exit codes
  Command         the Command protocol and the registry
  Commands        one small type per subcommand
  Context         what every command gets
  Arguments       flags, options and positionals, no dependency
Sources/selftest  drives Policy, Checker (against a fake backend and an in-memory store), State, Config, Format, LaunchAgent and Shell;
                  runs on a bare Command Line Tools install, which has neither XCTest nor the swift-testing macros
```

Swift 6 with strict concurrency, no dependencies. Built with Apple Swift 6.4 on macOS 27.2.

## What it does not do

It does not shrink a running VM. It does not touch Docker Desktop, OrbStack or Lima instances outside Colima. It never starts a profile; your next `colima start` or a `docker` wrapper of your own does that.
