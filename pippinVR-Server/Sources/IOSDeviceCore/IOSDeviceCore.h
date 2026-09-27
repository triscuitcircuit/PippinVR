#ifndef IOS_DEVICE_CORE_H
#define IOS_DEVICE_CORE_H

#import <Foundation/Foundation.h>

@interface IOSDeviceInfo : NSObject
@property (nonatomic, strong) NSString* name;
@property (nonatomic, strong) NSString* uniqueID;
@property (nonatomic, strong) NSString* modelID;
@property (nonatomic, assign) BOOL isIOSDevice;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@end

@interface IOSDeviceCore : NSObject

+ (BOOL)enableScreenCaptureDevices;

+ (NSArray<IOSDeviceInfo*>*)waitForDevicesWithTimeout:(int)timeout_ms;

+ (NSArray<IOSDeviceInfo*>*)discoverDevices;

@end

#endif // IOS_DEVICE_CORE_H
