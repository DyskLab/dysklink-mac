#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// An extra display that macOS treats like a real monitor. It exists while this object is alive.
@interface DLVirtualDisplay : NSObject

/// `width` and `height` are in points. With `hiDPI`, macOS draws twice as many pixels, so text stays sharp.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                                hiDPI:(BOOL)hiDPI
                               serial:(uint32_t)serial;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

@end

NS_ASSUME_NONNULL_END
