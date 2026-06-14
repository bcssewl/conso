#ifndef CSENSORS_H
#define CSENSORS_H

#include <CoreFoundation/CoreFoundation.h>

/// Reads Apple's temperature sensors (the same ones Activity Monitor uses) via the
/// IOHIDEventSystem. Non-root. Returns { sensor "Product" name : °C }.
/// Caller owns the returned dictionary.
CF_RETURNS_RETAINED CFDictionaryRef CSensorsCopyTemperatures(void);

#endif /* CSENSORS_H */
