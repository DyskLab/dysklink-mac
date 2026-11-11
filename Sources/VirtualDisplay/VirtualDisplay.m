#import "VirtualDisplay.h"

// CoreGraphics has these classes since macOS 11 but no public header. The same declarations are used by Chromium.
@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

@implementation DLVirtualDisplay {
    CGVirtualDisplay *_display;
}

- (nullable instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height
                                hiDPI:(BOOL)hiDPI serial:(uint32_t)serial {
    if (!(self = [super init])) return nil;
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass || width == 0 || height == 0) return nil;

    NSUInteger scale = hiDPI ? 2 : 1;
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)(width * scale);
    descriptor.maxPixelsHigh = (unsigned int)(height * scale);
    // About a 6.7-inch phone. macOS uses it to pick a sensible default size for text.
    descriptor.sizeInMillimeters = CGSizeMake(150, 150.0 * height / width);
    descriptor.vendorID = 0x4459;  // "DY"
    descriptor.productID = 0x4c4b; // "LK"
    descriptor.serialNum = serial;
    descriptor.terminationHandler = ^(id unused, CGVirtualDisplay *display) {};

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == 0) return nil;

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[[[modeClass alloc] initWithWidth:(unsigned int)(width * scale) height:(unsigned int)(height * scale) refreshRate:60], [[modeClass alloc] initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:60]];
    if (![display applySettings:settings]) return nil;
    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
