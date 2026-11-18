// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <AudioToolbox/AudioToolbox.h>
enum {
    kOberVaveProgram = 65,
    kOberVaveMaster = 66,
    kOberVavePan = 67,
    kOberVaveSync = 68,
    kOberVaveGrid = 69,
    kOberVaveArpSelection = 70,
    kOberVaveLatchSelection = 71,
    kOberVaveModulationBase = 72,
    kOberVaveControllerBase = 97,
    kOberVaveLegacyWheel = 96,
    kOberVaveParameterCount = 209,
    kOberVaveMeters = 64000,
    kOberVaveKeyboard = 64001,
    kOberVaveControllerLearn = 64002,
    kOberVavePanic = 64003
};
typedef struct {
    float left, right;
    float voices[8];
    float tempo;
    UInt32 hostClock;
} OberVaveMeters;
typedef struct { UInt32 status, data1, data2; } OberVaveKeyboardEvent;
#ifdef __cplusplus
extern "C" {
#endif
OSStatus OberVaveCocoaViewInfo(void* info);
double ov_lfo_rate_hz(UInt32 value);
#ifdef __cplusplus
}
#endif
