#import "RemoteDisplayBridge.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

static void *APDisplaySymbol(const char *primary, const char *fallback) {
    static void *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL); });
    if (!library) return NULL;
    void *symbol = dlsym(library, primary);
    return symbol ?: dlsym(library, fallback);
}

bool APDisplayPowerIsAvailable(void) {
    return APDisplaySymbol("SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled") &&
           APDisplaySymbol("SLSGetDisplayList", "CGSGetDisplayList");
}

CGError APConfigureDisplayEnabled(CGDisplayConfigRef configuration, CGDirectDisplayID display, bool enabled) {
    typedef CGError (*Function)(CGDisplayConfigRef, CGDirectDisplayID, bool);
    Function function = (Function)APDisplaySymbol("SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled");
    return function ? function(configuration, display, enabled) : kCGErrorNotImplemented;
}

CGError APGetAllDisplayList(uint32_t capacity, CGDirectDisplayID *displays, uint32_t *count) {
    typedef CGError (*Function)(uint32_t, CGDirectDisplayID *, uint32_t *);
    Function function = (Function)APDisplaySymbol("SLSGetDisplayList", "CGSGetDisplayList");
    return function ? function(capacity, displays, count) : kCGErrorNotImplemented;
}

// CGVirtualDisplay is not declared in the SDK. Keep its ABI in this one module;
// absence of a class/selector must disable the feature, never break app launch.
@interface APDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) unsigned int vendorID, productID, serialNum;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@interface APDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface APDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end
@interface APDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(nonatomic, readonly) unsigned int displayID;
@end

bool APVirtualDisplayIsAvailable(void) {
    Class display = NSClassFromString(@"CGVirtualDisplay");
    Class descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settings = NSClassFromString(@"CGVirtualDisplaySettings");
    Class mode = NSClassFromString(@"CGVirtualDisplayMode");
    if (!display || !descriptor || !settings || !mode) return false;
    NSDictionary *requirements = @{
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"],
        @"CGVirtualDisplayDescriptor": @[@"setQueue:", @"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setSizeInMillimeters:", @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:"],
        @"CGVirtualDisplaySettings": @[@"setHiDPI:", @"setModes:"],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"]
    };
    for (NSString *name in requirements) {
        for (NSString *selector in requirements[name]) {
            if (![NSClassFromString(name) instancesRespondToSelector:NSSelectorFromString(selector)]) return false;
        }
    }
    return true;
}

APVirtualDisplayRef APVirtualDisplayCreate(uint32_t width, uint32_t height, bool hiDPI, uint32_t serial) {
    if (![NSThread isMainThread] || !APVirtualDisplayIsAvailable() || !serial ||
        width < 640 || height < 480 || width > 3840 || height > 3840 ||
        (uint64_t)width * height > 3840ull * 2160 || width % 2 || height % 2) return NULL;
    @try {
        APDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"Vela Remote Display";
        descriptor.maxPixelsWide = width; descriptor.maxPixelsHigh = height;
        descriptor.vendorID = 0x4157; descriptor.productID = 1; descriptor.serialNum = serial;
        descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 144, height * 25.4 / 144);
        descriptor.redPrimary = CGPointMake(.64, .33); descriptor.greenPrimary = CGPointMake(.30, .60);
        descriptor.bluePrimary = CGPointMake(.15, .06); descriptor.whitePoint = CGPointMake(.3127, .3290);
        APDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display) return NULL;
        APDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = hiDPI ? 1 : 0;
        unsigned int scale = hiDPI ? 2 : 1;
        APDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width / scale height:height / scale refreshRate:60];
        if (!mode) return NULL;
        settings.modes = @[mode];
        if (![display applySettings:settings] || !display.displayID) return NULL;
        return (__bridge_retained const void *)display;
    } @catch (NSException *exception) { return NULL; }
}

uint32_t APVirtualDisplayGetID(APVirtualDisplayRef value) {
    if (!value || ![NSThread isMainThread]) return 0;
    return [(__bridge APDisplay *)value displayID];
}

void APVirtualDisplayDestroy(APVirtualDisplayRef value) {
    if (!value) return;
    // The caller must stop capture and restore its selected physical display first.
    CFRelease(value);
}
