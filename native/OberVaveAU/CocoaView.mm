// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import <AudioUnit/AUCocoaUIView.h>
#import "UIBridge.h"

extern "C" void* OberVaveCreateView(AudioUnit unit);

@interface OberVaveCocoaView : NSObject <AUCocoaUIBase>
@end
@implementation OberVaveCocoaView
- (unsigned)interfaceVersion { return 0; }
- (NSString*)description { return @"OberVave"; }
- (NSView*)uiViewForAudioUnit:(AudioUnit)unit withSize:(NSSize)size
{
    return (__bridge_transfer NSView*)OberVaveCreateView(unit);
}
@end

OSStatus OberVaveCocoaViewInfo(void* info)
{
    auto* view = static_cast<AudioUnitCocoaViewInfo*>(info);
    auto* bundle = [NSBundle bundleForClass:[OberVaveCocoaView class]];
    view->mCocoaAUViewBundleLocation = (__bridge_retained CFURLRef)bundle.bundleURL;
    view->mCocoaAUViewClass[0] = CFSTR("OberVaveCocoaView");
    return noErr;
}
