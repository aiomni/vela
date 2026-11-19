# CoreHID signed authorization validation — November 6, 2026

## Current result

**The authorization gate is now independently narrowed to AMFI/profile validation.**
The same compiled lab executable was packaged twice using the project's existing
fixed certificate, the same lab App ID and hardened-runtime settings. The control
without the HID entitlement launches and reaches CoreHID (initialization returns
`nil`). The otherwise matched app claiming
`com.apple.developer.hid.virtual.device=true` is killed with `SIGKILL`, without any
probe JSON. Its exact artifact path appears in an `amfid` diagnostic reporting:

- Domain: `AppleMobileFileIntegrityError`
- Code: `-413`
- Reason: **`No matching profile found`**

`codesign --verify --deep --strict` passes for both artifacts. This establishes
cryptographic integrity of these local signatures, **not** authorization for the
restricted HID claim. The existing fixed certificate has no Apple Team Identifier,
and neither signature satisfies the Apple signing-anchor requirement. No profile
was embedded. No certificate was replaced, no keychain trust was changed, no
hardened-runtime setting was disabled, and no security enforcement was bypassed.

**There is still no activated virtual touchscreen or native AppKit touch/gesture
acceptance.** The tested modes cannot dispatch Input reports. No `--run` experiment
was attempted on the current desktop; the entitled process did not return probe
results, so its internal execution progress must not be invented.

## Evidence and strength

[Matched comparison and cross-checks](vela-corehid-touch-signed-comparison-2026-11-06.json)
contains the signed metadata, runtime captures and exact-artifact security result.

| Check | Control without HID entitlement | App with HID entitlement |
| --- | --- | --- |
| Input build executable SHA-256 | Same `3de577390d48d023cb1ae1654b707eb2d4da9c17e0c5649d38c69dd65b3fc03e` | Same |
| Existing fixed certificate and certificate-bound requirement | Verified | Verified |
| Hardened runtime | Enabled | Enabled |
| Apple Team Identifier / Apple signing anchor | Absent / not verified | Absent / not verified |
| Signed HID entitlement | Absent | Boolean true |
| Embedded provisioning profile | None | None |
| Actual launch result | Normal process exit 2, probe JSON | Return -9 / SIGKILL, no probe JSON |
| Actual CoreHID result | Initializer nil, entitlement absent | Not observable: process killed |
| Actual report dispatch | Zero, `inputReportAttempted=false` | No probe output; mode is no-input by construction |
| Native touch/gesture acceptance | Not established | Not established |

The runtime executable hashes match their respective signed artifacts. The
comparison generator checks that the pre-lab-signing build executable hash is
identical, the runtime hashes match, the control submits zero reports, the capture
runner did not cause the SIGKILL, and the exact entitled artifact has the -413
profile diagnostic. Different final executable hashes are expected because the
signature/entitlement contents differ.

Primary component evidence:

- [Matched control runtime](vela-corehid-touch-control-runtime-2026-11-06.json)
- [Matched entitled runtime](vela-corehid-touch-entitled-runtime-2026-11-06.json)
- [Exact-artifact AMFI diagnostic](vela-corehid-touch-matched-security-2026-11-06.json)
- [Control signing metadata](../.build/touch-lab/1accce95-dfdb-48ac-ad92-5eef447c7952/signing-evidence.json)
- [Entitled signing metadata](../.build/touch-lab/5b17c004-381b-40e6-ba10-0b023758408e/signing-evidence.json)

Earlier independent attempts in this continuation also produced an entitled
SIGKILL and a runnable no-entitlement control. Their
[sanitized security extraction](vela-corehid-touch-security-details-2026-11-06.json)
and [earlier control result](vela-corehid-touch-signed-control-2026-11-06.json)
are retained; the matched comparison above is the stronger evidence. No historical
[initial prototype result](vela-corehid-touch-prototype-2026-11-06.md) or earlier
probe has been rewritten to claim later testing.

## What needs to be obtained next

The first result only showed an absent signature entitlement. The additional
experiment demonstrates that adding the public Boolean claim to the current
local-certificate signature is insufficient: **this macOS 27.0.1 host rejects the
claim because it cannot find a matching profile.** Do not try to make it work by
removing hardened runtime, ad-hoc re-signing, altering AMFI, using root, or adding
Apple-private entitlements.

The team needs an Apple-supported signing/provisioning combination authorizing
this exact entitlement for the process that calls CoreHID:

1. An appropriate Apple Developer team signing certificate and team-owned App ID
   for the lab. Retain `app.aiomni.awakepet` and the shipped controller identifier
   for production; this experiment uses `app.aiomni.awakepet.touchlab` only.
2. An Apple-issued profile eligible for the intended development/distribution
   route whose entitlement allowlist includes
   `com.apple.developer.hid.virtual.device=true`, matching the App ID, team and
   signing certificate. A hand-edited or unrelated profile is not authorization.
3. The actual creator's signed entitlement claim and any required macOS app
   container/profile placement (`Contents/embedded.provisionprofile`). Re-run the
   strict signature check and runtime probe; a packaging success is not enough.

The existing local certificate works for the control, but does not constitute an
Apple team signing identity or grant for this capability. No account Portal,
Apple-issued profile or additional certificate was accessed or generated here.
The exact certificate/profile combinations and Developer ID eligibility must be
confirmed for the user's team. The experiment does not show whether an ordinary
team can enable this key directly or whether Apple-managed approval is necessary.
The public key reference still does not specify that approval procedure.

If the capability is not exposed in Xcode / Developer Portal, send
[Apple Developer Support](https://developer.apple.com/support/) this concrete
inquiry rather than assuming the similarly named DriverKit form applies:

> We use the public CoreHID HIDVirtualDevice API for an app-owned virtual
> touchscreen on macOS 27.0.1. Our matched no-entitlement lab launches using an
> existing fixed local certificate. Adding the Boolean entitlement
> com.apple.developer.hid.virtual.device=true, while retaining hardened runtime,
> causes AMFI to kill the process with AppleMobileFileIntegrityError -413:
> No matching profile found. Which Apple Developer team capability/request and
> certificate/profile combinations authorize this exact CoreHID entitlement for
> development and Developer ID distribution? Is managed approval required, and
> how should the entitlement be enabled on the App ID and provisioned? This is
> not a DriverKit extension or a request for Apple-private HID event dispatch.

References: [HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device),
[macOS provisioning/signing explanation](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles),
and [managed-capabilities process](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities/).
The latter describes the general mechanism, not proof of this key's availability
or approval classification. Accessibility / Device Control / Input Monitoring,
Screen Recording or administrator consent cannot replace the missing profile.

## New repeatable tooling

[Build helper](../scripts/build-touch-lab.py) creates only new UUID-scoped lab
artifacts under `.build/touch-lab`. It loads the existing signing identity without
printing it, refuses missing/ad-hoc identities, does a real fixed-certificate
preflight, retains default certificate-bound designated requirements, enables
hardened runtime, and records only allowlisted signature fields. Production
packaging, certificates, profiles and installed apps are untouched.

```sh
python3 scripts/build-touch-lab.py --control-without-hid-entitlement
python3 scripts/build-touch-lab.py
```

The control is an explicitly requested separate experiment, not a fallback after
signing failure. A first helper attempt failed while preserving metadata on a
copy of the system `true` executable; the helper now copies bytes and executable
permissions instead of system metadata. The original system file is never modified.
Failed staging artifacts were retained, not silently replaced or deleted.

[No-input capture runner](../scripts/probe-signed-touch-lab.py) verifies an isolated
lab artifact and records normal exit, signal termination or probe JSON. It refuses
production paths and never accepts `--run`. It never saves raw stderr, complete
process command lines or certificate identity information.

```sh
python3 scripts/probe-signed-touch-lab.py \
  --app PATH_TO_ISOLATED_LAB.app --mode probe --output NEW.json
```

Capture-runner exit 0 means **evidence capture completed**, not successful device
creation. Inspect `processReturnCode`, `terminationSignal`, `probeOutputReceived`
and the nested probe result. An output path is new-file-only at the final write.

## Safe next rung before input injection

The lab now offers **`--activate-probe`**, distinct from both plain `--probe` and
live `--run`:

1. Create and activate the public `HIDVirtualDevice` with its delegate.
2. Enumerate only the per-run virtual device identity.
3. Create a public `HIDDeviceClient` using that exact virtual device's
   `deviceReference`, never a physical-device manager scan or seize.
4. Read back descriptor, primary usage and parser element counts.
5. Issue Feature Get report ID 2 with a one-second timeout; verify full `[2,2]`
   response and delegate actor callback counters.
6. Tear down without calling `dispatchInputReport`, including cleanup.

[Virtual device implementation](../Sources/VelaTouchLab/VirtualTouchscreen.swift)
now tracks whether an Input report was ever attempted. The previous cleanup would
submit two empty Input scans after any activation; that is fixed so a no-input
activation test really sends zero Input reports. Feature-only client scope ends
before the virtual-device reference is released. Reference release is not claimed
as independently observed kernel-device removal.

The final [entry point](../Sources/VelaTouchLab/main.swift) also requires this
own-device readback/feature rung before its live sequence. Current matched launch
captures were taken before that final additional live-mode guard; their exact
binary hashes are preserved. The final source builds, but **no activated-device
roundtrip or removal was executed**, because the signing/creation gate did not
pass. Optional attached event-driver subtree inspection remains future work.

Public API sources:
[own-device reference](https://developer.apple.com/documentation/corehid/hidvirtualdevice/devicereference),
[bounded Feature Get](https://developer.apple.com/documentation/corehid/hiddeviceclient/dispatchgetreportrequest(type:id:timeout:)),
and [CoreHID virtual-device creation](https://developer.apple.com/documentation/corehid/creatingvirtualdevices).
These declarations were read in both installed SDKs; existence is not live success.

Once a legitimate profile-backed lab starts, use `--probe`, then
`--activate-probe`, then an isolated non-sensitive native-touch experiment. No
mouse movement, shallow display-property echo or successful feature reply alone
proves WindowServer/AppKit direct-touch promotion. Display binding remains
experimental, and HID input remains system-wide, not window-sandboxed.

## Validation in this continuation

- Matched signing, certificate-bound requirement and strict bundle checks passed.
- Input build hash and runtime/signed executable correspondence passed.
- No-entitlement control executed; HID initializer nil and zero reports recorded.
- Entitled app was killed; exact-artifact AMFI/profile error corroborated.
- `swift test --filter TouchLabCoreTests`: six descriptor/report tests passed;
  final source including no-input inspection compiled.
- [Python safety tests](../Tests/TouchLab/test_signed_touch_lab.py): five passed,
  covering ad-hoc rejection before secret access/build, redacted signing failure
  and timeout, refusal of input-injection mode and refusal of production targets.
- Localization and companion preservation checks passed.
- No real touch reports, native gestures, TCC requests, display/power changes,
  driver installation, signed production replacement or security-policy changes.

Full unrelated Swift/browser transport/live display suites were not repeated for
these isolated signing/inspection changes. The original prototype record contains
the prior full Swift run. See [TESTING](../TESTING.txt) for current executable steps.
