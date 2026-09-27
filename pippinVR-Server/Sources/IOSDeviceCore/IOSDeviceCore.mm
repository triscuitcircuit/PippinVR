#import "IOSDeviceCore.h"
#import <Logger.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <CoreVideo/CoreVideo.h>

@implementation IOSDeviceInfo
@end

@implementation IOSDeviceCore

+ (BOOL)enableScreenCaptureDevices {
    LOG_INFO(@"Enabling CoreMediaIO screen capture devices");

    CMIOObjectPropertyAddress addr = {
        kCMIOHardwarePropertyAllowScreenCaptureDevices,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain
    };
    uint32_t value = 1;
    OSStatus st = CMIOObjectSetPropertyData(kCMIOObjectSystemObject, &addr, 0, nullptr,
                                           sizeof(value), &value);

    if (st != 0) {
        LOG_ERROR(@"Failed to enable screen capture devices, status: %d", st);
    }

    LOG_INFO(@"Screen capture devices enabled");

    CMIOObjectPropertyAddress wirelessAddr = {
        kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain
    };
    OSStatus wirelessSt = CMIOObjectSetPropertyData(kCMIOObjectSystemObject, &wirelessAddr, 0, nullptr,
                             sizeof(value), &value);

    if (wirelessSt != 0) {
        LOG_WARNING(@"Failed to enable wireless screen capture devices. Device status: %d", wirelessSt);
    }

    LOG_INFO(@"Wireless screen capture devices enabled");

    return st == 0;
}

+ (NSArray<IOSDeviceInfo*>*)waitForDevicesWithTimeout:(int)timeout_ms {
    const double step = 0.25;
    int elapsed_ms = 0;

    while (elapsed_ms <= timeout_ms) {
        NSArray<IOSDeviceInfo*>* devices = [self discoverDevices];

        for (IOSDeviceInfo* device in devices) {
            if (device.isIOSDevice) {
                LOG_INFO(@"Found iOS device: %@", device.name);
                return devices;
            }
        }

        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:step]];
        elapsed_ms += (int)(step * 1000);
    }

    return [self discoverDevices];
}

+ (NSArray<IOSDeviceInfo*>*)discoverDevices {

    LOG_DEBUG(@"Starting external device discovery");

    NSMutableArray<IOSDeviceInfo*>* result = [NSMutableArray array];

    AVCaptureDeviceDiscoverySession* session = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
                              mediaType:nil  // CRITICAL: nil, not AVMediaTypeVideo!
                               position:AVCaptureDevicePositionUnspecified];

    LOG_DEBUG(@"Found %lu external device(s)", (unsigned long)session.devices.count);

    for (AVCaptureDevice* d in session.devices) {
        IOSDeviceInfo* info = [[IOSDeviceInfo alloc] init];
        info.name = d.localizedName;
        info.uniqueID = d.uniqueID;
        info.modelID = d.modelID;

        info.isIOSDevice = [d.modelID isEqualToString:@"iOS Device"];

        if (d.formats.count > 0) {
            AVCaptureDeviceFormat* format = d.formats[0];
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            info.width = dimensions.width;
            info.height = dimensions.height;
        } else {
            info.width = 0;
            info.height = 0;
        }

        [result addObject:info];

        if (info.isIOSDevice) {
            LOG_INFO(@"iOS screen device found: %@ (%dx%d, %lu format(s))",
                    info.name, info.width, info.height, (unsigned long)d.formats.count);
        } else {
            LOG_DEBUG(@"External device: %@ [%@] (%dx%d)",
                     info.name, info.modelID, info.width, info.height);
        }
    }

    int iosDeviceCount = 0;
    for (IOSDeviceInfo* info in result) {
        if (info.isIOSDevice) {
            iosDeviceCount++;
        }
    }

    LOG_INFO(@"Discovery complete: %lu total, %d iOS screen device(s)",
            (unsigned long)result.count, iosDeviceCount);

    if (iosDeviceCount == 0) {
        LOG_DEBUG(@"No iOS screen devices found (check USB connection, trust status, permissions)");
    }

    return result;
}

@end
