// SPDX-License-Identifier: GPL-3.0-only
#include "SustainGesture.h"
#include <cassert>
#include <cstdio>

using namespace ob1::music;
int main()
{
    using Result = SustainGesture::Result;
    SustainGesture gesture;
    const Source a {SourceKind::ExternalMIDI, 1}, b {SourceKind::ExternalMIDI, 2};
    constexpr uint32_t rate = 44100, press = 13230;
    for (uint32_t quarter : {8820u, 22050u, 66150u}) {
        gesture.clear();
        Frame now = UINT64_C(0x1fffffff0);
        for (uint32_t tap = 0; tap < 3; ++tap) {
            assert(gesture.input(a, 0, 0, now, quarter, rate) == Result::None);
            assert(gesture.input(a, 0, 96, now, quarter, rate) == Result::None);
            assert(gesture.input(a, 0, 127, now + 1, quarter, rate) == Result::None);
            assert(gesture.input(a, 0, 64, now + 2, quarter, rate) == Result::None);
            assert(gesture.input(a, 0, 31, now + press, quarter, rate) ==
                (tap == 2 ? Result::Stop : Result::None));
            now += press + quarter;
        }
        for (bool longPress : {false, true}) {
            gesture.clear(); now = 0;
            for (uint32_t tap = 0; tap < 3; ++tap) {
                assert(gesture.input(a, 0, 127, now, quarter, rate) == Result::None);
                assert(gesture.input(a, 0, 0, now + press + (longPress ? 1 : 0), quarter, rate) == Result::None);
                now += press + quarter + 1;
            }
        }
    }
    gesture.clear();
    for (uint32_t tap = 0; tap < 2; ++tap) {
        gesture.input(a, 0, 127, tap * 1000, 22050, rate);
        assert(gesture.input(a, 0, 0, tap * 1000 + 500, 22050, rate) == Result::None);
    }
    gesture.input(b, 0, 127, 2000, 22050, rate);
    assert(gesture.input(b, 0, 0, 2500, 22050, rate) == Result::None);
    gesture.input(a, 1, 127, 2000, 22050, rate);
    assert(gesture.input(a, 1, 0, 2500, 22050, rate) == Result::None);
    gesture.releaseSource(a);
    gesture.input(a, 0, 127, 3000, 22050, rate);
    assert(gesture.input(a, 0, 0, 3500, 22050, rate) == Result::None);
    gesture.clear();
    for (uint32_t i = 0; i < 1056; ++i)
        assert(gesture.input({SourceKind::ExternalMIDI, i}, 0, 127, 0, 22050, rate) == Result::None);
    assert(gesture.input({SourceKind::ExternalMIDI, 1056}, 0, 127, 0, 22050, rate) == Result::Full);
    std::puts("PASS Sustain gesture: exact 300ms/quarter boundaries, tempo extremes, long press/gap rejection, chatter, source/channel isolation, disconnect/reset, 64-bit time and bounded capacity");
}
