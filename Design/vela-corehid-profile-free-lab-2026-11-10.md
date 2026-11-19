# CoreHID lab without an Apple profile — November 10, 2026

Apple DTS describes a test setup that allows a binary to claim the CoreHID
entitlement without an Apple-issued profile. It relaxes SIP and AMFI at boot
on the test system. The lab still carries a valid local signature and the
Boolean `com.apple.developer.hid.virtual.device` entitlement. The policy
change applies to the whole system that boots with it. A disposable macOS
guest scopes that change to the guest. [CoreHID DTS guidance](https://developer.apple.com/forums/thread/820708) and [AMFI boot argument](https://developer.apple.com/forums/thread/125048).

## Prepared lab and host baseline

The fresh `VelaTouchLab.app` is in
`.build/touch-lab/78eee69e-fbcb-4105-a30e-7789eb1ee72a/`. Copy the app as a
bundle so its signed resources and localization are available in the guest.
The local certificate, hardened runtime, and certificate-bound designated
requirement pass strict signature verification. The bundle claims the HID
entitlement and has no embedded provisioning profile.

The stock-policy launch on macOS 27.0.1 (26A434) was terminated with
`SIGKILL` before it emitted probe JSON. The exact artifact matched one
`amfid` diagnostic with `-413 / No matching profile found`. The filtered
evidence files are `stock-policy-probe.json` and `stock-policy-amfi.json`
in the same artifact directory. SIP was enabled on the host. There was no
configured macOS guest found in the local VM locations inspected, so the
guest procedure remains untested here.

## Run on a disposable macOS 27 guest

Install a clean macOS 27 guest from an Apple restore image. Tart can create
the guest from an IPSW and start its Recovery environment with
`tart run --recovery vela-touch-lab`. A regular boot uses
`tart run vela-touch-lab`. Use a local test account and transfer only the
test app bundles. [Apple macOS virtualization](https://developer.apple.com/documentation/virtualization/virtualize-macos-on-a-mac), [Tart setup](https://tart.run/quick-start/), [Tart Recovery flag](https://github.com/openai/tart/blob/main/Sources/tart/Commands/Run.swift).

Take a baseline by running the copied app's `--probe` in the guest before
changing the guest policy. Then boot the **guest** into Recovery, open its
Terminal, and run `csrutil disable`. Boot the guest normally. The following
commands assume a new guest with an empty `boot-args` variable. If the guest
already has boot arguments, record the original value for restoration before
setting the test argument.

```sh
# Guest Terminal only.
csrutil status
nvram boot-args
sudo nvram boot-args="amfi_get_out_of_my_way=1"
sudo shutdown -r now
```

After the guest restarts, verify `sw_vers` and `csrutil status`, then run the
copied app as the logged-in guest user. Set `VELA_TOUCH_LAB_APP` to its path.

```sh
vela_touch_lab="${VELA_TOUCH_LAB_APP:?}/Contents/MacOS/VelaTouchLab"
"$vela_touch_lab" --probe --output guest-create.json
"$vela_touch_lab" --activate-probe --duration 5 --output guest-activate.json
```

Creation passes only if the first probe reports both
`virtualDeviceEntitlementPresent: true` and `deviceCreated: true`. The
second probe must verify enumeration and a Feature Get round trip with zero
input reports. If either fails, preserve the JSON or the launch error before
trying any gesture sequence.

For the target-display check, run Vela inside the guest and use its web
controller to create an active extended virtual display. Use at least
800 × 600 logical points. Verify window placement, then run the live sequence
with only the lab interacting with the guest desktop.

```sh
"$vela_touch_lab" --receiver-only --vela-virtual-display --duration 2
"$vela_touch_lab" --run --vela-virtual-display --isolated-desktop --duration 15 --output guest-touch.json
```

The sequence must observe direct `NSTouch` lifecycles on the selected screen,
scroll-view movement during the one-finger stage, and native magnification
during the two-finger stage. Guest success establishes the behavior in that
guest build. The physical Mac's display association still needs its own test.

When finished with a disposable guest, shut it down and discard it or restore
its pre-test snapshot. To keep it, restore the original `boot-args` value
(or use `sudo nvram -d boot-args` if it was originally absent), then run
`csrutil enable` in guest Recovery and boot again.

## Other local paths checked

`amfi-allow` adds a per-binary hash exception for Apple-private entitlement
validation. Its documented setup needs root and a SIP debugging relaxation,
and it edits the running AMFI daemon's state. Its controls cover private
entitlements, with no demonstrated result for the CoreHID profile denial
observed here. [Author's implementation and controls](https://github.com/Lakr233/amfi-allow/blob/main/RESEARCH.md).

A physical USB HID gadget avoids creating an app-owned virtual device. On
the same macOS build as this host, a published USB experiment got as far as
digitizer enumeration, then WindowServer rejected display association because
the HID service lacked a usable `displayUUID`. [USB digitizer experiment](https://github.com/glasses666/macos27-external-touch/blob/main/EVIDENCE.md).
