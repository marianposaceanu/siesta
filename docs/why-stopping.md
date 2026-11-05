# Why siesta stops the VM instead of shrinking it

The long form, with the measurements and the sources, is the article
[An idle Colima VM keeps 5 GB of a Mac's memory](https://ark.marianposaceanu.com/idle-colima-vm-memory-macos).
This page is the short technical record behind the design.

## What was measured

On a 16 GB M4 MacBook Air running macOS 27.2, Colima 0.10.3 and Lima 2.2.1, a 6 GiB
profile had been running for ninety minutes with no container inside it.

| Inside the guest | MB |
| --- | --- |
| processes: dockerd, containerd, lima-guestagent, systemd | 373 |
| page cache from image pulls and builds | 4,089 |
| never touched since boot | 1,640 |

| On the host | |
| --- | --- |
| resident | 161 MB |
| compressed or on the swap file | 5.1 GB |
| share of everything out of RAM | 53% |
| swap file before and after the VM started | 2 GB, 3 GB |

## Why the host cannot take it back

- The Virtualization framework commits a guest page the first time the guest writes it and
  never learns when the guest frees it. Linux fills free memory with file cache by design, so a
  guest touches nearly its whole allocation once and keeps it.
- The guest has a virtio balloon (`virtio8`, driver `virtio_balloon`) and Lima attaches it,
  but Lima 2.2.1 never resizes it and has no configuration key for it. The pull request that
  adds adaptive ballooning, [lima-vm/lima#4828](https://github.com/lima-vm/lima/pull/4828), was
  open at the time of writing; the request is [lima-vm/lima#4220](https://github.com/lima-vm/lima/issues/4220).
- The balloon object lives inside the process that owns the VM, Lima's host agent. The
  framework has no cross-process handle to it, so no outside tool can drive it.
- `echo 3 > /proc/sys/vm/drop_caches` inside the guest frees pages in the guest's accounting
  only. The host is not told and keeps its copy.
- A secondary source reports that on recent macOS versions the framework does not release
  pages the guest gives up through the balloon either; this was not reproduced here.

## What that leaves

| Option | Gain | Cost |
| --- | --- | --- |
| stop the VM when idle | all of it, in seconds | about 20 s to start again |
| cap the guest lower | halves the ceiling | a restart; bigger builds fail |
| OrbStack, Docker Desktop Resource Saver, Apple `container` | dynamic by design | a different tool |
| patch Lima | the proper fix | maintainers unconvinced; a fork to carry |

Stopping is the only option that needs no change to the tools already in use, so siesta
does that, from an hourly launchd agent, with a conservative definition of idle and a rule
that an unclear observation never stops anything. See the README for the definition.
