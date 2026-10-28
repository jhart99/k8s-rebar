# k8s-rebar

Enable Resizable BAR (ReBAR) on Intel Arc GPUs from Kubernetes, on boards whose
BIOS never offered the option.

Ships as a tiny Alpine image plus two ways to run it: a Helm chart that deploys a
DaemonSet, and a standalone Pod manifest for a quick one-node test.

## The problem

Some server and workstation boards shipped without a "Resizable BAR" toggle — the
Supermicro H11SSL-i is the well-known example; the option did not appear until the
H12 series. ReBAR is what lets the CPU map the *entire* GPU VRAM into the address
space instead of a small aperture (AMD markets the same idea as SAM).

Without it, the `xe` driver tries to grow the BAR at boot and fails:

```console
xe 0000:08:00.0: [drm] Attempting to resize bar from 256MiB -> 16384MiB
xe 0000:08:00.0: BAR 2 [mem size 0x400000000 64bit pref]: can't assign; no space
xe 0000:08:00.0: [drm] Failed to resize BAR2 to 16384M (-ENOSPC). Consider enabling 'Resizable BAR' support in your BIOS
xe 0000:08:00.0: [drm] Small BAR device
```

`lspci` agrees — a 12 GiB card exposing a 256 MiB window:

```console
Region 2: Memory at 1ffe0000000 (64-bit, prefetchable) [size=256M]
```

### Why the kernel can't just fix it

The BIOS builds the PCI memory map using the card's *default* BAR size (256 MiB
for these Arc parts). By the time the kernel loads, that map is already committed.
The driver can ask for a larger BAR, but there is no free space in the window the
firmware allotted, and the firmware will not redo the map — redoing it means
re-enumerating the PCIe tree, which would yank devices that are already in use.

So the resize fails and the GPU stays in "Small BAR" mode.

## The workaround

ReBAR is just a capability register. Instead of patching firmware (see
[ReBarUEFI](https://github.com/xCuri0/ReBarUEFI) — invasive, and it can brick a
board), you can set the requested size directly and force the re-enumeration the
firmware declined to do:

1. Find the discrete Arc GPU and its PCIe root port.
2. Unbind the GPU driver.
3. Write the target size exponent into the Resizable BAR control register.
4. Remove the root port and rescan the bus, so Linux re-lays the bridge window
   with the larger BAR in mind.

This is the technique from [andersevenrud's H11SSL-i + Arc B580 write-up](https://gist.github.com/andersevenrud/eec93e9151117bc0d6b6133b40eaffa5),
repackaged as a container so it can run at boot across a cluster instead of as
hand-maintained initramfs scripts on one box. Credit for the register-level
approach belongs entirely to that gist.

This project generalizes it in two ways:

- **Card detection** — the gist matches a hardcoded B580 device ID
  (`8086:e20b`); this scans vendor `8086` across display classes `0300`/`0380`
  and skips integrated graphics on bus `0000:00:`.
- **Target size** — the exponent is configurable instead of fixed at `14`.

## How the script works

`entrypoint.sh` is POSIX sh on Alpine, driving `lspci` and `setpci` from
`pciutils`.

**Size mapping.** The register holds an exponent where the window is
`2^(exp+20)` bytes, so the script converts a human size to an exponent:

| `GPU_MEMORY_SIZE` | Exponent | Window |
|-------------------|----------|--------|
| `2GB`  | 11 | 2 GiB  |
| `4GB`  | 12 | 4 GiB  |
| `8GB`  | 13 | 8 GiB  |
| `16GB` | 14 | 16 GiB |
| `32GB` | 15 | 32 GiB |

Note that BAR sizes are powers of two, so a 12 GiB B580 is given a **16 GiB**
window — the smallest power of two that covers it. Setting `16GB` on a B580 is
correct, not a typo.

**The steps:**

1. **Discover** the GPU — `lspci -D -d 8086::0300`, falling back to class
   `0380`, filtering out anything on bus `0000:00` (that's the integrated GPU).
   `TARGET_PCI_BDF` overrides discovery when a node has several cards.
2. **Bail early** if `lspci -vv` already reports the target size — the script is
   idempotent, so a DaemonSet re-queue is a no-op.
3. **Walk up sysfs** from the GPU through its parent chain until it reaches a
   `pci0000:XX` node. That's the PCIe root port sitting directly under the root
   complex — the bridge whose window needs re-laying.
4. **Dry-run gate.** With `DRY_RUN=true` it logs what it *would* do and exits,
   touching nothing. Useful for validating detection before letting it loose.
5. **Unbind** the bound driver (`xe` or `i915`, whichever is attached).
6. **Program the register.** Clear the command register first, read
   `ECAP_REBAR+0x08.l`, then splice the exponent into bits 12:8 while preserving
   everything else:

   ```sh
   old=$(setpci -s "$GPU" ECAP_REBAR+0x08.l)
   new=$(printf '%08x' $(( (0x$old & 0xFFFFE0FF) | (TARGET_EXP << 8) )))
   setpci -s "$GPU" ECAP_REBAR+0x08.l="$new"
   ```

7. **Remove the root port** (`echo 1 > .../remove`), then **rescan** the bus
   (`echo 1 > /sys/bus/pci/rescan`). The kernel re-enumerates from scratch and
   allocates the bridge window the firmware would have, had it understood ReBAR.
   The driver rebinds against the new, large BAR.

On completion it writes a UTC timestamp to `/host-run/arc-rebar-ready` (a marker
you can mount out for an initContainer or readiness gate), then sleeps forever so
the DaemonSet pod stays alive rather than crash-looping.

## Repository layout

```
.github/workflows/release.yaml       Build image, push to GHCR, publish chart as OCI
charts/intel-arc-rebar/
  Chart.yaml                         Chart metadata
  values.yaml                        Defaults and documented knobs
  templates/
    _helpers.tpl                     name / fullname / labels helpers
    daemonset.yaml                   The DaemonSet
deploy/standalone-pod.yaml           Single-node Pod manifest, no Helm required
scripts/push-helm-oci.sh             lint → package → helm push to ghcr.io
Dockerfile                           Alpine 3.21 + pciutils
entrypoint.sh                        The actual ReBAR logic
```

## Prerequisites

- **`Above 4G Decoding` enabled in BIOS.** Without it there is no room for a
  large aperture and the rescan will simply fail to place the BAR.
- **A 64-bit-capable PCIe slot with headroom.** On the H11SSL-i only the bottom
  x16 slot (`CPU SLOT2 PCI-E 3.0 X16`) worked — it's wired straight to the CPU
  with enough address space for a 16 GiB window. Other boards will differ.
- **`xe` driver**, kernel 6.12+. Older Ubuntu needs the HWE kernel.
- **On Talos:** privileged workloads must be permitted in your machine config,
  and the pod needs to schedule onto the GPU node.
- **Nothing else driving the GPU** at the moment it runs. The remove/rescan cycle
  drops every device behind that root port, briefly — on Arc that's the GPU and
  its audio function.

The bare-metal write-up also sets `pci=realloc` on the kernel command line. Here
the script performs its own remove/rescan, which is what that flag exists to make
possible — but if the BAR still fails to grow, adding `pci=realloc` is the first
thing to try.

## Install

### Helm

```sh
helm install intel-arc-rebar oci://ghcr.io/jhart99/charts/intel-arc-rebar \
  --namespace kube-system \
  --set gpuMemorySize=16GB
```

To target one node explicitly:

```sh
helm install intel-arc-rebar oci://ghcr.io/jhart99/charts/intel-arc-rebar \
  --namespace kube-system \
  --set gpuMemorySize=16GB \
  --set nodeSelector."kubernetes\.io/hostname"=talos-gpu-worker-01
```

### Standalone pod

No Helm involved — useful for a single test node:

```sh
kubectl apply -f deploy/standalone-pod.yaml
kubectl -n kube-system logs -f pod/intel-arc-rebar
```

## Configuration

| Value | Default | Purpose |
|-------|---------|---------|
| `image.repository` | `ghcr.io/jhart99/intel-arc-rebar` | Image location |
| `image.tag` | `""` (→ `appVersion`) | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Pull policy |
| `gpuMemorySize` | `16GB` | Target BAR size: `2GB`/`4GB`/`8GB`/`16GB`/`32GB` |
| `targetPciBdf` | `""` | Pin a specific device, e.g. `0000:03:00.0` |
| `dryRun` | `false` | Detect and log, but change nothing |
| `sleepAfter` | `true` | Sleep forever when done (keep DaemonSet pod alive) |
| `nodeSelector` | `{}` | Restrict to GPU nodes (NFD labels, hostname) |
| `tolerations` | `Exists` | Run on tainted GPU / control-plane nodes |
| `affinity` | `{}` | Standard pod affinity |
| `priorityClassName` | `system-node-critical` | Run before regular workloads |
| `updateStrategy` | `RollingUpdate`, `maxUnavailable: 100%` | All at once, since this is a boot-time action |
| `resources` | `10m/16Mi` req, `100m/64Mi` lim | Intentionally tiny — the work is microseconds |

Useful Node Feature Discovery selectors:

```yaml
nodeSelector:
  feature.node.kubernetes.io/pci-0300_8086.present: "true"
```

## Verifying it worked

The pod log reports the detected GPU, its root port, and the BAR layout after the
rescan:

```console
[arc-rebar] Found GPU: 0000:08:00.0 behind Root Port: 0000:00:03.0
[arc-rebar] New BAR layout for 0000:08:00.0:
Region 0: Memory at ea000000 (64-bit, non-prefetchable) [size=16M]
Region 2: Memory at 19400000000 (64-bit, prefetchable) [size=16G]
```

On the node, the driver should no longer say "Small BAR device":

```sh
dmesg | grep -iE 'xe.*(BAR|VRAM|resize)'
```

```console
xe 0000:08:00.0: [drm] VISIBLE VRAM: 0x0000019400000000, 0x0000000400000000
xe 0000:08:00.0: [drm] CPU accessible size 0x00000002fb800000
```

`CPU accessible size` now matching the real VRAM is the success signal.

## Caveats

- **The BAR does not survive a cold boot.** Firmware re-enumerates at every POST,
  so the setting is lost and the script must run again — which is exactly why this
  is a DaemonSet rather than a one-shot job.
- **Remove/rescan is not surgical.** Every device behind that root port drops and
  comes back. Expect a brief graphics/audio interruption, and do not run this on a
  node hosting something that must not blink.
- **Register-level, at your own risk.** This writes PCI configuration space. The
  sizes accepted are bounded to the supported set precisely so a bad value can't
  be requested, but it is still firmware-adjacent territory.
- **Not all boards and slots cooperate.** Whether the rescan can place a 16 GiB
  window depends on the board's topology and which slot the card occupies.
- **Untested combinations are untested.** Known-good is the H11SSL-i with an Arc
  B580 in the bottom x16 slot. The class-based detection is meant to widen that,
  but has not been validated on every Arc part.

## Releasing

Push to `main` (or tag `v*`) and `.github/workflows/release.yaml` builds the image
and publishes the chart to `ghcr.io/jhart99/charts`. Manually:

```sh
export GITHUB_OWNER=jhart99
export GHCR_TOKEN=<token with write:packages>
./scripts/push-helm-oci.sh charts/intel-arc-rebar
```

The script lints, packages (optionally stamping `CHART_VERSION`), and pushes.

## Credits

The register-level technique is from
[andersevenrud's gist on enabling ReBAR on a Supermicro H11SSL-i with an Intel Arc B580](https://gist.github.com/andersevenrud/eec93e9151117bc0d6b6133b40eaffa5).
This repo adapts it for containers and Kubernetes; the underlying method and the
write-up explaining *why* it works are theirs.

## License

[MIT](LICENSE)
