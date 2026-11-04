# Vela IPv6 support acceptance — 2026-11-04

## Behavior

- Remote address discovery includes routed IPv6 unicast addresses on LAN interfaces, and on tunnel interfaces when all-interface listening is selected. Addresses are canonicalized before advertisement and certificate generation.
- IPv4 and IPv6 use separate HTTPS listeners. The IPv6 listener explicitly sets IPV6_V6ONLY at the IPv6 socket option level, preserving IPv4 availability without port conflicts. LAN-only mode binds selected addresses and both loopbacks; all-interface mode binds both wildcards.
- IPv6 connection URLs use bracketed authorities. Host validation accepts equivalent IPv6 spellings only for configured local addresses and the configured port. Origin validation remains exact and rejects other origins.
- Certificate SANs include IPv6 addresses and the IPv6 loopback. Address-driven certificate renewal preserves the private key. Existing fingerprint verification and browser trust requirements still apply.
- Native controller input accepts bracketed IPv6 URLs and displays an IPv6 example. Web requests remain relative to the current origin. WebRTC candidates remain opaque; IPv6 candidate gathering on Wi-Fi is explicitly enabled in the shared native peer configuration.
- Unspecified, multicast, loopback, IPv4-mapped and link-local IPv6 addresses are excluded from advertised interface addresses. Scoped link-local connections are outside this implementation; use routed ULA or global IPv6 addresses.

## Validation

- Swift suite: IPv4/IPv6 real HTTPS with anchored certificate and hostname verification, dual listener shutdown, IPv6 Host/Origin checks, address filtering and authority canonicalization, certificate renewal/key preservation, and existing authentication/session/network recovery regressions.
- Web client Node suite: 19 tests passed.
- Localization and companion integrity checks passed; catalogs remain identical.

## Review fixes

- IPv6 enumeration queries address-specific flags through a read-only `SIOCGIFAFLAG_IN6` C bridge, using SDK types and constants. It excludes tentative, duplicated, detached, anycast, CLAT46, deprecated, and temporary privacy addresses. Query failures omit the IPv6 address while retaining eligible IPv4 addresses.
- Temporary privacy address additions/removals no longer affect advertised addresses, listener rebinding, certificate SANs, or remembered-browser certificate bindings. Stable autoconfigured, DHCP, and manual addresses remain eligible.
- Validation after the review fixes: the full `swift test` run passed (one existing test skipped); all 19 web client Node tests, localization validation, companion integrity, and `git diff --check` passed.
- Regression coverage includes individual address flags in LAN/all-interface modes, successful kernel loopback flag lookup and query failures, an IPv4 TLS request after filtering unavailable IPv6 addresses, and unchanged certificate bytes/fingerprint plus valid remembered-device credentials across simulated privacy address rotation.

## Live verification limits

The running installed app has not been replaced or restarted. Tests use isolated temporary remote stores and certificates. Phone-to-office VPN routing, browser certificate enrollment on the phone, and IPv6-only WebRTC media/control have not been verified on the real network. Application support does not establish a VPN route or override network access policies.
