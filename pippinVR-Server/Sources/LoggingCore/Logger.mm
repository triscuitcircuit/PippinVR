#import "Logger.h"
#import <os/log.h>

static IOSLogLevel minimumLogLevel = IOSLogLevelDebug;

#define COLOR_RESET   "\033[0m"
#define COLOR_CYAN    "\033[0;36m"
#define COLOR_GREEN   "\033[0;32m"
#define COLOR_YELLOW  "\033[0;33m"
#define COLOR_RED     "\033[0;31m"

void IOSLog(IOSLogLevel level, NSString* module, const char* function, NSString* format, ...) {
    if (level < minimumLogLevel) {
        return;
    }

    const char* color;
    NSString* levelName;
    switch (level) {
        case IOSLogLevelDebug:
            color = COLOR_CYAN;
            levelName = @"DEBUG";
            break;
        case IOSLogLevelInfo:
            color = COLOR_GREEN;
            levelName = @"INFO";
            break;
        case IOSLogLevelWarning:
            color = COLOR_YELLOW;
            levelName = @"WARN";
            break;
        case IOSLogLevelError:
            color = COLOR_RED;
            levelName = @"ERROR";
            break;
    }

    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString* funcName = [NSString stringWithUTF8String:function];
    NSRange parenRange = [funcName rangeOfString:@"("];
    if (parenRange.location != NSNotFound) {
        funcName = [funcName substringToIndex:parenRange.location];
    }

    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss.SSS"];
    NSString* timestamp = [formatter stringFromDate:[NSDate date]];

    NSString* logMessage = [NSString stringWithFormat:@"[%@] %s%@%s [%@.%@] %@",
                           timestamp, color, levelName, COLOR_RESET, module, funcName, message];

    NSLog(@"%@", logMessage);
}
