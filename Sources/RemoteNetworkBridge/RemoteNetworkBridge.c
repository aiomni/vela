#include "RemoteNetworkBridge.h"
#include <netinet6/in6_var.h>
#include <string.h>
#include <sys/ioctl.h>

int VelaIPv6AddressFlags(int socketFD, const char *interfaceName,
                         const struct sockaddr_in6 *address, int32_t *flags) {
    struct in6_ifreq request = {0};
    if (strlcpy(request.ifr_name, interfaceName, sizeof(request.ifr_name)) >= sizeof(request.ifr_name)) {
        return -1;
    }
    request.ifr_ifru.ifru_addr = *address;
    if (ioctl(socketFD, SIOCGIFAFLAG_IN6, &request) < 0) {
        return -1;
    }
    *flags = request.ifr_ifru.ifru_flags6;
    return 0;
}
