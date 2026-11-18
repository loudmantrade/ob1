// SPDX-License-Identifier: GPL-3.0-only
#import <Cocoa/Cocoa.h>
#import <AudioUnit/AUCocoaUIView.h>
#include "UIBridge.h"
#include <algorithm>
#include <array>
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
static void clickTrackedControl(NSView* view, CGFloat x, CGFloat yFromTop)
{
    const NSPoint point = [view convertPoint:NSMakePoint(x,
        view.isFlipped ? yFromTop : view.bounds.size.height - yFromTop) toView:nil];
    auto* up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber
        context:nil eventNumber:1 clickCount:1 pressure:0];
    [NSApp postEvent:up atStart:NO];
    mouse(view, NSEventTypeLeftMouseDown, x, yFromTop);
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
            click(view, view.bounds.size.width * 3 / 10, view.bounds.size.height - 25);
            check(AudioUnitSetParameter(unit, 47, kAudioUnitScope_Global, 0, 0, 0), "disable arp");
            check(AudioUnitSetParameter(unit, 63, kAudioUnitScope_Global, 0, 0, 0), "disable latch");
            check(AudioUnitSetParameter(unit, kOberVaveArpSelection, kAudioUnitScope_Global, 0, 2, 0),
                "select arp while disabled");
            check(AudioUnitSetParameter(unit, kOberVaveLatchSelection, kAudioUnitScope_Global, 0, 2, 0),
                "select latch while disabled");
            pump();
            click(view, 825, 181);
            click(view, 1000, 181);
            Float32 arpMode = 0, latchMode = 0;
            check(AudioUnitGetParameter(unit, 47, kAudioUnitScope_Global, 0, &arpMode), "arp button");
            check(AudioUnitGetParameter(unit, 63, kAudioUnitScope_Global, 0, &latchMode), "latch button");
            require(arpMode == 2 && latchMode == 2, "enable buttons did not recall selected modes");
            snapshot(view, [output stringByAppendingPathComponent:@"editor-more.png"]);
            click(view, 825, 181);
            click(view, 1000, 181);
            check(AudioUnitGetParameter(unit, 47, kAudioUnitScope_Global, 0, &arpMode), "arp off button");
            check(AudioUnitGetParameter(unit, 63, kAudioUnitScope_Global, 0, &latchMode), "latch off button");
            require(arpMode == 0 && latchMode == 0, "enable buttons did not turn features off");
            click(view, view.bounds.size.width * 7 / 10, view.bounds.size.height - 25);
            check(AudioUnitSetParameter(unit, kOberVaveModulationBase, kAudioUnitScope_Global, 0, 3, 0), "matrix source automation");
            check(AudioUnitSetParameter(unit, kOberVaveModulationBase + 1, kAudioUnitScope_Global, 0, 4, 0), "matrix destination automation");
            check(AudioUnitSetParameter(unit, kOberVaveModulationBase + 2, kAudioUnitScope_Global, 0, 96, 0), "matrix depth automation");
            pump();
            snapshot(view, [output stringByAppendingPathComponent:@"editor-matrix.png"]);
            // The unified page starts with a 237-point control row and 12-point spacing.
            constexpr CGFloat lfoControlsHeight = 249;
            for (const auto& control : {std::array<CGFloat, 3>{29, 275, 170},
                                       std::array<CGFloat, 3>{32, 455, 170},
                                       std::array<CGFloat, 3>{33, 455, 270},
                                       std::array<CGFloat, 3>{34, 825, 170}}) {
                Float32 before = 0, after = 0;
                const auto id = AudioUnitParameterID(control[0]);
                check(AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &before), "LFO control before");
                mouse(view, NSEventTypeLeftMouseDown, control[1], control[2]);
                mouse(view, NSEventTypeLeftMouseDragged, control[1], control[2] - 25);
                mouse(view, NSEventTypeLeftMouseUp, control[1], control[2] - 25);
                pump();
                check(AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &after), "LFO control after");
                require(after > before, "unified page LFO control did not update its parameter");
                check(AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, before, 0), "restore LFO control");
            }
            Gestures matrixGestures;
            AUEventListenerRef matrixListener = nullptr;
            check(AUEventListenerCreate(parameterEvent, &matrixGestures, CFRunLoopGetCurrent(),
                kCFRunLoopDefaultMode, 0.01, 0.01, &matrixListener), "matrix gesture listener");
            AudioUnitEvent matrixEvent{};
            matrixEvent.mArgument.mParameter = {unit, kOberVaveModulationBase + 2, kAudioUnitScope_Global, 0};
            for (auto type : {kAudioUnitEvent_BeginParameterChangeGesture,
                              kAudioUnitEvent_ParameterValueChange, kAudioUnitEvent_EndParameterChangeGesture}) {
                matrixEvent.mEventType = type;
                check(AUEventListenerAddEventType(matrixListener, &matrixGestures, &matrixEvent), "matrix gesture event");
            }
            mouse(view, NSEventTypeLeftMouseDown, 629, 260 + lfoControlsHeight);
            mouse(view, NSEventTypeLeftMouseDragged, 240, 260 + lfoControlsHeight);
            mouse(view, NSEventTypeLeftMouseUp, 240, 260 + lfoControlsHeight);
            pump();
            Float32 matrixDepth = 0;
            check(AudioUnitGetParameter(unit, kOberVaveModulationBase + 2, kAudioUnitScope_Global, 0,
                &matrixDepth), "read matrix slider");
            require(matrixDepth < 64, ("matrix depth slider did not set a negative amount: " +
                std::to_string(matrixDepth)).c_str());
            require(matrixGestures.begin > 0 && matrixGestures.change > 0 && matrixGestures.end > 0,
                "matrix slider did not notify host automation gestures");
            AUListenerDispose(matrixListener);
            click(view, 940, 260 + lfoControlsHeight);
            check(AudioUnitGetParameter(unit, kOberVaveModulationBase + 2, kAudioUnitScope_Global, 0,
                &matrixDepth), "read zero depth");
            require(matrixDepth == 64, "matrix ZERO did not center depth");
            click(view, 505, 230 + lfoControlsHeight);
            Float32 matrixSource = 99, matrixDestination = 99;
            check(AudioUnitGetParameter(unit, kOberVaveModulationBase, kAudioUnitScope_Global, 0,
                &matrixSource), "read reset source");
            check(AudioUnitGetParameter(unit, kOberVaveModulationBase + 1, kAudioUnitScope_Global, 0,
                &matrixDestination), "read reset destination");
            require(matrixSource == 0 && matrixDestination == 0, "matrix RESET did not clear route");
            click(view, 20, 162 + lfoControlsHeight);
            Float32 legacyWheel = 1;
            check(AudioUnitGetParameter(unit, kOberVaveLegacyWheel, kAudioUnitScope_Global, 0,
                &legacyWheel), "read legacy wheel toggle");
            require(legacyWheel == 0, "matrix legacy wheel toggle did not update host parameter");
            click(view, view.bounds.size.width * 9 / 10, view.bounds.size.height - 25);
            check(AudioUnitSetParameter(unit, kOberVaveControllerBase, kAudioUnitScope_Global, 0, 2, 0), "controller input automation");
            check(AudioUnitSetParameter(unit, kOberVaveControllerBase + 2, kAudioUnitScope_Global, 0, 1, 0), "controller mode automation");
            check(AudioUnitSetParameter(unit, kOberVaveControllerBase + 5, kAudioUnitScope_Global, 0, 96, 0), "controller depth automation");
            pump();
            snapshot(view, [output stringByAppendingPathComponent:@"editor-controllers.png"]);
            {
                Gestures controllerGestures;
                AUEventListenerRef controllerListener = nullptr;
                check(AUEventListenerCreate(parameterEvent, &controllerGestures, CFRunLoopGetCurrent(),
                    kCFRunLoopDefaultMode, 0.01, 0.01, &controllerListener), "controller gesture listener");
                AudioUnitEvent event{};
                event.mArgument.mParameter = {unit, kOberVaveControllerBase + 5, kAudioUnitScope_Global, 0};
                for (auto type : {kAudioUnitEvent_BeginParameterChangeGesture,
                                  kAudioUnitEvent_ParameterValueChange, kAudioUnitEvent_EndParameterChangeGesture}) {
                    event.mEventType = type;
                    check(AUEventListenerAddEventType(controllerListener, &controllerGestures, &event), "controller gesture event");
                }
                mouse(view, NSEventTypeLeftMouseDown, 700, 338);
                mouse(view, NSEventTypeLeftMouseDragged, 250, 338);
                mouse(view, NSEventTypeLeftMouseUp, 250, 338);
                pump();
                Float32 value = 0;
                check(AudioUnitGetParameter(unit, kOberVaveControllerBase + 5, kAudioUnitScope_Global, 0,
                    &value), "controller depth drag");
                require(value < 64, "Controller DEPTH drag did not update parameter");
                require(controllerGestures.begin > 0 && controllerGestures.change > 0 && controllerGestures.end > 0,
                    "Controller DEPTH gesture did not notify host");
                check(AUListenerDispose(controllerListener), "dispose Controller listener");
                click(view, 1047, 338);
                check(AudioUnitGetParameter(unit, kOberVaveControllerBase + 5, kAudioUnitScope_Global, 0,
                    &value), "controller ZERO");
                require(value == 64, "Controller ZERO did not center");
                clickTrackedControl(view, 565, 304);
                check(AudioUnitGetParameter(unit, kOberVaveControllerBase + 6, kAudioUnitScope_Global, 0,
                    &value), "controller override");
                require(value == 1, "Controller OVERRIDE did not update parameter");
                click(view, 439, 269);
                check(AudioUnitGetParameter(unit, kOberVaveControllerBase, kAudioUnitScope_Global, 0,
                    &value), "controller reset");
                require(value == 0, "Controller RESET did not disable route");
                click(view, 366, 269);
                check(MusicDeviceMIDIEvent(unit, 0xD0, 80, 0, 0), "Controller Learn pressure");
                float l[32]{}, r[32]{};
                struct { UInt32 count; AudioBuffer buffers[2]; } audio{
                    2, {{1, sizeof(l), l}, {1, sizeof(r), r}}};
                AudioTimeStamp time{};
                time.mFlags = kAudioTimeStampSampleTimeValid;
                time.mSampleTime = 32;
                AudioUnitRenderActionFlags flags = 0;
                check(AudioUnitRender(unit, &flags, &time, 0, 32,
                    reinterpret_cast<AudioBufferList*>(&audio)), "Controller Learn render");
                pump();
                check(AudioUnitGetParameter(unit, kOberVaveControllerBase, kAudioUnitScope_Global, 0,
                    &value), "learned controller UI source");
                require(value == 130, "Controller LEARN UI did not assign channel aftertouch");
            }
            click(view, view.bounds.size.width * 5 / 10, view.bounds.size.height - 25);
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
            click(view, view.bounds.size.width / 10, view.bounds.size.height - 25);
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
