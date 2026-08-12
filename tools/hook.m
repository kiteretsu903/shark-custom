// Injected via DYLD_INSERT_LIBRARIES into Shark Arsenal to capture every BLE
// write it makes. CoreBluetooth funnels all GATT writes through
// -[CBPeripheral writeValue:forCharacteristic:type:], so hooking that one
// method yields the exact command bytes + target characteristic.
//
// Build:
//   clang -dynamiclib -framework Foundation -framework CoreBluetooth \
//         -o tools/hook.dylib tools/hook.m
//   codesign -s - tools/hook.dylib
//
// Output is appended to /tmp/shark_capture.log

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>

static void logline(NSString *s) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [NSDate date], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/shark_capture.log"];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/shark_capture.log"
                                                contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/shark_capture.log"];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static NSString *hexOf(NSData *d) {
    const unsigned char *b = d.bytes;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x ", b[i]];
    return s;
}

static IMP orig_write = NULL;
static void hooked_write(id self, SEL _cmd, NSData *data, CBCharacteristic *ch, NSInteger type) {
    logline([NSString stringWithFormat:@"WRITE char=%@ type=%ld data=[%@]",
             ch.UUID.UUIDString, (long)type, hexOf(data)]);
    ((void(*)(id, SEL, NSData*, CBCharacteristic*, NSInteger))orig_write)(self, _cmd, data, ch, type);
}

static IMP orig_setnotify = NULL;
static void hooked_setnotify(id self, SEL _cmd, BOOL enabled, CBCharacteristic *ch) {
    logline([NSString stringWithFormat:@"SETNOTIFY %d char=%@", enabled, ch.UUID.UUIDString]);
    ((void(*)(id, SEL, BOOL, CBCharacteristic*))orig_setnotify)(self, _cmd, enabled, ch);
}

__attribute__((constructor))
static void init_hook(void) {
    logline(@"=== hook loaded into Shark Arsenal ===");
    Class cls = objc_getClass("CBPeripheral");
    if (!cls) { logline(@"CBPeripheral class not found"); return; }

    Method mW = class_getInstanceMethod(cls, @selector(writeValue:forCharacteristic:type:));
    if (mW) { orig_write = method_getImplementation(mW);
              method_setImplementation(mW, (IMP)hooked_write);
              logline(@"hooked writeValue:forCharacteristic:type:"); }

    Method mN = class_getInstanceMethod(cls, @selector(setNotifyValue:forCharacteristic:));
    if (mN) { orig_setnotify = method_getImplementation(mN);
              method_setImplementation(mN, (IMP)hooked_setnotify);
              logline(@"hooked setNotifyValue:forCharacteristic:"); }
}
