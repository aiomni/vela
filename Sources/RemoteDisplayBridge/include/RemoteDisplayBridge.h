#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>

// Private CoreGraphics interfaces are resolved at runtime. All display operations
// must be made on the main thread. Ownership is explicit across the Swift bridge.
typedef const void *APVirtualDisplayRef;
bool APVirtualDisplayIsAvailable(void);
APVirtualDisplayRef APVirtualDisplayCreate(uint32_t pixelWidth, uint32_t pixelHeight,
                                          bool hiDPI, uint32_t serialNumber);
uint32_t APVirtualDisplayGetID(APVirtualDisplayRef display);
void APVirtualDisplayDestroy(APVirtualDisplayRef display);

bool APDisplayPowerIsAvailable(void);
CGError APConfigureDisplayEnabled(CGDisplayConfigRef configuration, CGDirectDisplayID display, bool enabled);
CGError APGetAllDisplayList(uint32_t capacity, CGDirectDisplayID *displays, uint32_t *count);
