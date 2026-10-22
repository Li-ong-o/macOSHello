#include "lowlevel.h"
#include <dlfcn.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOKitLib.h>

int SACLockScreenImmediate(void)
{
    // BLEUnlock links this Mach-O image directly. Loading it by path keeps the
    // same system lock action without requiring the private framework at build time.
    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
        RTLD_LAZY
    );
    if (!handle) {
        return -1;
    }

    typedef int (*SACLockScreenImmediateFunction)(void);
    SACLockScreenImmediateFunction lock =
        (SACLockScreenImmediateFunction)dlsym(handle, "SACLockScreenImmediate");
    if (!lock) {
        return -2;
    }

    return lock();
}

void wakeDisplay(void)
{
    static IOPMAssertionID assertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("macOSHello"), kIOPMUserActiveLocal, &assertionID);
}

void sleepDisplay(void)
{
    mach_port_t mainPort;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 120000
    if (__builtin_available(macOS 12.0, *)) {
        mainPort = kIOMainPortDefault;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        mainPort = kIOMasterPortDefault;
#pragma clang diagnostic pop
    }
#else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    mainPort = kIOMasterPortDefault;
#pragma clang diagnostic pop
#endif

    io_registry_entry_t reg = IORegistryEntryFromPath(mainPort, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
    }
}
