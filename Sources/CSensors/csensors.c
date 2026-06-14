#include "CSensors.h"

// Private IOHIDEventSystem symbols (exported by IOKit.framework). Declared here
// because they aren't in any public SDK header. This is the same interface that
// Activity Monitor / iStats / stats use to read Apple Silicon temperatures.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef CFTypeRef IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFStringRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)
#define kHIDPage_AppleVendor 0xff00
#define kHIDUsage_AppleVendor_TemperatureSensor 0x0005

CFDictionaryRef CSensorsCopyTemperatures(void) {
    int page = kHIDPage_AppleVendor;
    int usage = kHIDUsage_AppleVendor_TemperatureSensor;
    CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageNum, usageNum };
    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFMutableDictionaryRef result = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client) {
        IOHIDEventSystemClientSetMatching(client, matching);
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (services) {
            CFIndex count = CFArrayGetCount(services);
            for (CFIndex i = 0; i < count; i++) {
                IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
                if (!service) continue;
                CFStringRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
                IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
                if (name && event) {
                    double temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
                    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &temp);
                    CFDictionarySetValue(result, name, num);
                    CFRelease(num);
                }
                if (event) CFRelease(event);
                if (name) CFRelease(name);
            }
            CFRelease(services);
        }
        CFRelease(client);
    }
    CFRelease(matching);
    CFRelease(pageNum);
    CFRelease(usageNum);
    return result;
}
