#ifndef IOS_DEVICE_CORE_LOGGER_H
#define IOS_DEVICE_CORE_LOGGER_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, IOSLogLevel) {
    IOSLogLevelDebug = 0,
    IOSLogLevelInfo = 1,
    IOSLogLevelWarning = 2,
    IOSLogLevelError = 3
};

#define LOG_DEBUG(fmt, ...) IOSLog(IOSLogLevelDebug, @"IOSDeviceCore", __FUNCTION__, fmt, ##__VA_ARGS__)
#define LOG_INFO(fmt, ...) IOSLog(IOSLogLevelInfo, @"IOSDeviceCore", __FUNCTION__, fmt, ##__VA_ARGS__)
#define LOG_WARNING(fmt, ...) IOSLog(IOSLogLevelWarning, @"IOSDeviceCore", __FUNCTION__, fmt, ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...) IOSLog(IOSLogLevelError, @"IOSDeviceCore", __FUNCTION__, fmt, ##__VA_ARGS__)

void IOSLog(IOSLogLevel level, NSString* module, const char* function, NSString* format, ...) NS_FORMAT_FUNCTION(4,5);

#endif // IOS_DEVICE_CORE_LOGGER_H
