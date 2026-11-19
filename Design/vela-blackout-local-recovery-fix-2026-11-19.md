# Local input recovery repair

The failed companion blackout was recovered through the watchdog’s explicit
restore request. Both original physical displays returned online and awake, and
the virtual replacements were removed.

A read-only HID-tap check then received 21 real local input events. All passed
the existing physical-process filter and carried no Vela remote-input tag.
Their timestamps used Mach absolute ticks, while the new blackout boundary had
been recorded in nanoseconds. The incompatible comparison rejected fresh input.

The repair removes event timestamp comparison entirely. The watchdog ignores
input while the display transaction is pending. Once the transaction succeeds,
an empty committed-state marker enables local input restoration. The callback
checks that active state, the physical-input classification, and the remote-input
exclusion. The recovery watchdog starts after the five-second countdown.

## Validation

- Swift tests passed for keyboard and mouse input in the inactive and active
  states, including rejection of synthetic and Vela-tagged remote input.
- A signed build 14 companion-mode live probe disabled both physical displays,
  kept the local session unlocked, and reported only the two replacement virtual
  displays online during blackout.
- The watchdog restored the original displays with reason `local-input`.
  Restoration succeeded before the independent timeout request was needed.
  The original display IDs and backing resolutions matched after recovery.
- Build 14 was installed through normal application shutdown and atomic bundle
  replacement, with the existing signing certificate and designated requirement
  verified. Vela was relaunched afterward.
