// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import <AudioUnit/AUCocoaUIView.h>
#include "UIBridge.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>

static void check(OSStatus status, const char* message)
{
    if (status != noErr) throw std::runtime_error(std::string(message) + ": " + std::to_string(status));
}
static void require(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}
static void pump()
{
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
}
static void mouse(NSView* view, NSEventType type, CGFloat x, CGFloat yFromTop)
{
    const NSPoint point = [view convertPoint:NSMakePoint(x,
        view.isFlipped ? yFromTop : view.bounds.size.height - yFromTop) toView:nil];
    NSEvent* event = [NSEvent mouseEventWithType:type location:point modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber
        context:nil eventNumber:1 clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
    [NSApp sendEvent:event];
}
static void click(NSView* view, CGFloat x, CGFloat yFromTop)
{
    mouse(view, NSEventTypeLeftMouseDown, x, yFromTop);
    mouse(view, NSEventTypeLeftMouseUp, x, yFromTop);
    pump();
}
struct Gestures { unsigned begin = 0, change = 0, end = 0; };
static void parameterEvent(void* context, void*, const AudioUnitEvent* event, UInt64, Float32)
{
    auto& gestures = *static_cast<Gestures*>(context);
    if (event->mEventType == kAudioUnitEvent_BeginParameterChangeGesture) ++gestures.begin;
    if (event->mEventType == kAudioUnitEvent_ParameterValueChange) ++gestures.change;
    if (event->mEventType == kAudioUnitEvent_EndParameterChangeGesture) ++gestures.end;
}
static void snapshot(NSView* view, NSString* path)
{
    [view layoutSubtreeIfNeeded];
    auto* bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    require(png && [png writeToFile:path atomically:YES], "cannot save UI snapshot");
}
int main(int argc, char** argv)
{
    if (argc != 3) { std::cerr << "usage: check_editor bundle output-directory\n"; return 2; }
    @autoreleasepool {
        AudioUnit unit = nullptr;
        try {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            [NSApp finishLaunching];
            NSURL* url = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
            NSBundle* bundle = [NSBundle bundleWithURL:url];
            require(bundle && [bundle load], "cannot load plugin");
            auto cfBundle = CFBundleCreate(nullptr, (__bridge CFURLRef)url);
            auto factory = reinterpret_cast<AudioComponentFactoryFunction>(
                CFBundleGetFunctionPointerForName(cfBundle, CFSTR("OberVaveFactory")));
            CFRelease(cfBundle);
            require(factory, "missing AU factory");
            AudioComponentDescription description{kAudioUnitType_MusicDevice, 'Obv1', 'Obvv', 0, 0};
            auto component = AudioComponentRegister(&description, CFSTR("OberVave UI test"), 512, factory);
            check(AudioComponentInstanceNew(component, &unit), "instantiate");
            check(AudioUnitInitialize(unit), "initialize");
            AudioUnitCocoaViewInfo info{};
            UInt32 size = sizeof(info);
            check(AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI,
                kAudioUnitScope_Global, 0, &info, &size), "Cocoa UI property");
            require(CFEqual(info.mCocoaAUViewBundleLocation, (__bridge CFURLRef)url), "wrong UI bundle");
            CFRelease(info.mCocoaAUViewBundleLocation);
            auto factoryClass = NSClassFromString((__bridge NSString*)info.mCocoaAUViewClass[0]);
            id<AUCocoaUIBase> uiFactory = [[factoryClass alloc] init];
            require(uiFactory && [uiFactory interfaceVersion] == 0, "Cocoa factory protocol");
            NSView* view = [uiFactory uiViewForAudioUnit:unit withSize:NSMakeSize(1100, 760)];
            require(view != nil && view.frame.size.width >= 980, "missing SwiftUI view");
            CFRelease(info.mCocoaAUViewClass[0]);
            NSWindow* window = [[NSWindow alloc] initWithContentRect:view.frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
            window.title = @"OberVave UI validation";
            window.contentView = view;
            [window makeKeyAndOrderFront:nil];
            pump();
            NSString* output = @(argv[2]);
            snapshot(view, [output stringByAppendingPathComponent:@"editor-ob1.png"]);
            click(view, view.bounds.size.width / 2, view.bounds.size.height - 25);
            check(AudioUnitSetParameter(unit, 47, kAudioUnitScope_Global, 0, 0, 0), "disable arp");
            check(AudioUnitSetParameter(unit, 63, kAudioUnitScope_Global, 0, 0, 0), "disable latch");
            check(AudioUnitSetParameter(unit, kOberVaveArpSelection, kAudioUnitScope_Global, 0, 2, 0),
                "select arp while disabled");
            check(AudioUnitSetParameter(unit, kOberVaveLatchSelection, kAudioUnitScope_Global, 0, 2, 0),
                "select latch while disabled");
            pump();
            click(view, 900, 181);
            click(view, 1030, 181);
            Float32 arpMode = 0, latchMode = 0;
            check(AudioUnitGetParameter(unit, 47, kAudioUnitScope_Global, 0, &arpMode), "arp button");
            check(AudioUnitGetParameter(unit, 63, kAudioUnitScope_Global, 0, &latchMode), "latch button");
            require(arpMode == 2 && latchMode == 2, "enable buttons did not recall selected modes");
            snapshot(view, [output stringByAppendingPathComponent:@"editor-more.png"]);
            click(view, 900, 181);
            click(view, 1030, 181);
            check(AudioUnitGetParameter(unit, 47, kAudioUnitScope_Global, 0, &arpMode), "arp off button");
            check(AudioUnitGetParameter(unit, 63, kAudioUnitScope_Global, 0, &latchMode), "latch off button");
            require(arpMode == 0 && latchMode == 0, "enable buttons did not turn features off");
            click(view, view.bounds.size.width * 5 / 6, view.bounds.size.height - 25);
            snapshot(view, [output stringByAppendingPathComponent:@"editor-effects.png"]);
            click(view, view.bounds.size.width - 110, 40);
            snapshot(view, [output stringByAppendingPathComponent:@"editor-keyboard.png"]);
            mouse(view, NSEventTypeLeftMouseDown, 110, 690);
            mouse(view, NSEventTypeLeftMouseDragged, 111, 689);
            pump();
            float left[1024]{}, right[1024]{};
            struct { UInt32 count; AudioBuffer buffers[2]; } audio{
                2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
            AudioTimeStamp time{};
            time.mFlags = kAudioTimeStampSampleTimeValid;
            AudioUnitRenderActionFlags flags = 0;
            check(AudioUnitRender(unit, &flags, &time, 0, 1024,
                reinterpret_cast<AudioBufferList*>(&audio)), "UI keyboard render");
            require(std::any_of(std::begin(left), std::end(left),
                [](float value) { return std::abs(value) > 1e-8; }), "UI key did not produce audio");
            mouse(view, NSEventTypeLeftMouseUp, 110, 690);
            pump();
            click(view, view.bounds.size.width - 110, 40);
            click(view, view.bounds.size.width / 6, view.bounds.size.height - 25);
            click(view, 442, 40);
            Float32 program = 0;
            check(AudioUnitGetParameter(unit, 65, kAudioUnitScope_Global, 0, &program), "program");
            require(program == 18, "UI program button did not update AU parameter");
            Gestures gestures;
            AUEventListenerRef listener = nullptr;
            check(AUEventListenerCreate(parameterEvent, &gestures, CFRunLoopGetCurrent(),
                kCFRunLoopDefaultMode, 0.01, 0.01, &listener), "create automation listener");
            for (const auto type : {kAudioUnitEvent_BeginParameterChangeGesture,
                     kAudioUnitEvent_ParameterValueChange, kAudioUnitEvent_EndParameterChangeGesture}) {
                AudioUnitEvent event{};
                event.mEventType = type;
                event.mArgument.mParameter = {unit, 12, kAudioUnitScope_Global, 0};
                check(AUEventListenerAddEventType(listener, nullptr, &event), "listen to knob");
            }
            Float32 before = 0, after = 0;
            check(AudioUnitGetParameter(unit, 12, kAudioUnitScope_Global, 0, &before), "cutoff before drag");
            mouse(view, NSEventTypeLeftMouseDown, 934, 187);
            mouse(view, NSEventTypeLeftMouseDragged, 934, 165);
            mouse(view, NSEventTypeLeftMouseUp, 934, 165);
            pump();
            check(AudioUnitGetParameter(unit, 12, kAudioUnitScope_Global, 0, &after), "cutoff after drag");
            check(AUListenerDispose(listener), "dispose automation listener");
            require(after > before, "knob drag did not update parameter");
            require(gestures.begin == 1 && gestures.end == 1 && gestures.change > 0,
                "knob did not notify host automation with one complete gesture");
            [window orderOut:nil];
            window.contentView = nil;
            view = nil;
            uiFactory = nil;
            pump();
            check(AudioUnitUninitialize(unit), "uninitialize");
            check(AudioComponentInstanceDispose(unit), "dispose");
            unit = nullptr;
            std::cout << "PASS Cocoa factory, shared panels, tabs, keyboard audio, program control, "
                         "knob drag and host automation gesture, snapshots\n";
            return 0;
        } catch (const std::exception& error) {
            std::cerr << "FAIL: " << error.what() << '\n';
            if (unit) { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); }
            return 1;
        }
    }
}
