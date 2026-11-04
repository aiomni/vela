#!/usr/bin/env python3
"""Inspect native touch prerequisites without creating devices or posting input."""

import argparse
import ctypes
import hashlib
import json
import platform
import plistlib
import subprocess
from pathlib import Path


def symbol_presence(library_path, names):
    try:
        library = ctypes.CDLL(library_path)
    except OSError as error:
        return {"loadError": str(error)}
    return {name: hasattr(library, name) for name in names}


def agent_entitlements(path):
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", path],
        capture_output=True, check=False, timeout=15,
    )
    if result.returncode:
        return {"inspectionExitCode": result.returncode}
    try:
        values = plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, ValueError):
        return {"inspectionError": "Entitlements were not a property list."}
    keys = (
        "com.apple.hid.manager.user-access-device",
        "com.apple.iohideventsystem.server",
        "com.apple.private.hid.client.event-dispatch",
        "com.apple.private.hid.client.event-monitor",
        "com.apple.developer.hid.virtual.device",
    )
    return {key: values.get(key) is True for key in keys}


def agent_touch_evidence(path, binary):
    imports = subprocess.run(
        ["/usr/bin/nm", "-u", path], capture_output=True,
        text=True, check=False, timeout=15,
    )
    imported_names = (
        "IOHIDVirtualServiceClientCreate",
        "IOHIDVirtualServiceClientDispatchEvent",
        "IOHIDUserDeviceCreateWithProperties",
        "IOHIDUserDeviceHandleReport",
        "HIDServicePropertiesV17cgDirectDisplayID",
        "HIDServicePropertiesV17displayIdentifier",
        "HIDServicePropertiesV17displayIntegrated",
    )
    markers = (
        "TouchScreenDigitizer",
        "supportsMacOSCompatibleTouchReports",
        "supportsNativeTouches",
        "Unable to configure displayUUID",
    )
    return {
        "importInspectionExitCode": imports.returncode,
        "importedSymbols": {
            name: name in imports.stdout for name in imported_names
        } if imports.returncode == 0 else {},
        "binaryMarkers": {name: name.encode() in binary for name in markers},
    }


def check_resource_access():
    """Open and close the HID resource user client; do not call its methods."""
    iokit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
    iokit.IOServiceMatching.restype = ctypes.c_void_p
    iokit.IOServiceGetMatchingService.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    iokit.IOServiceGetMatchingService.restype = ctypes.c_uint32
    iokit.IOServiceOpen.argtypes = [
        ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    iokit.IOServiceOpen.restype = ctypes.c_int32
    iokit.IOServiceClose.argtypes = [ctypes.c_uint32]
    iokit.IOServiceClose.restype = ctypes.c_int32
    iokit.IOObjectRelease.argtypes = [ctypes.c_uint32]
    iokit.IOObjectRelease.restype = ctypes.c_int32
    system.mach_error_string.argtypes = [ctypes.c_int32]
    system.mach_error_string.restype = ctypes.c_char_p

    matching = iokit.IOServiceMatching(b"IOHIDResource")
    if not matching:
        return {"error": "Could not construct a service match."}
    service = iokit.IOServiceGetMatchingService(0, matching)
    if not service:
        return {"serviceFound": False}
    connection = ctypes.c_uint32()
    task = ctypes.c_uint32.in_dll(system, "mach_task_self_").value
    try:
        result = iokit.IOServiceOpen(service, task, 0, ctypes.byref(connection))
        description = system.mach_error_string(result)
        return {
            "serviceFound": True,
            "openResult": f"0x{result & 0xffffffff:08x}",
            "description": description.decode() if description else None,
            "opened": result == 0,
            "deviceCreated": False,
            "reportsSubmitted": 0,
        }
    finally:
        if connection.value:
            iokit.IOServiceClose(connection.value)
        iokit.IOObjectRelease(service)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-hid-access", action="store_true",
        help="Open/close IOHIDResource to check access; never create a HID device.",
    )
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This probe requires macOS.")

    agent = "/usr/libexec/SidecarDisplayAgent"
    result = {
        "osVersion": platform.mac_ver()[0],
        "osBuild": subprocess.check_output(
            ["/usr/bin/sw_vers", "-buildVersion"], text=True, timeout=10,
        ).strip(),
        "scope": "No device creation, input posting, display changes, or TCC requests.",
        "iokitSymbols": symbol_presence(
            "/System/Library/Frameworks/IOKit.framework/IOKit", (
                "IOHIDUserDeviceCreateWithProperties",
                "IOHIDUserDeviceHandleReport",
                "IOHIDVirtualServiceClientCreate",
                "IOHIDVirtualServiceClientDispatchEvent",
                "IOHIDEventCreateDigitizerEvent",
                "IOHIDEventSystemClientDispatchEvent",
            ),
        ),
        "skyLightSymbols": symbol_presence(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", (
                "SLSSidecarGestureEventsSupported",
                "kSLSHIDEventTypeDirectTouch",
            ),
        ),
    }
    if Path(agent).is_file():
        binary = Path(agent).read_bytes()
        result["sidecarDisplayAgent"] = {
            "sha256": hashlib.sha256(binary).hexdigest(),
            "entitlements": agent_entitlements(agent),
            "touchEvidence": agent_touch_evidence(agent, binary),
        }
    if args.check_hid_access:
        result["hidResourceAccess"] = check_resource_access()
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
