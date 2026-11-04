#ifndef VELA_REMOTE_NETWORK_BRIDGE_H
#define VELA_REMOTE_NETWORK_BRIDGE_H

#include <netinet/in.h>
#include <stdint.h>

// Query address-specific flags without changing interface or address state.
int VelaIPv6AddressFlags(int socketFD, const char *interfaceName,
                         const struct sockaddr_in6 *address, int32_t *flags);

#endif
