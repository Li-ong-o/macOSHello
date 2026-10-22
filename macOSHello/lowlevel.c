#include "lowlevel.h"
#include <dlfcn.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOKitLib.h>

OSStatus SACLockScreenImmediate(void)
{
    void *handle = dlopen("/System/Library/PrivateFrameworks/LoginUICore.framework/LoginUICore", RTLD_LAZY);
    if (!handle) {
        return -1;
    }

    typedef OSStatus (*SACScreenLockFunction)(void);
    SACScreenLockFunction lock = (SACScreenLockFunction)dlsym(handle, "SACScreenLock");
    if (!lock) {
        dlclose(handle);
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
