// SPDX-License-Identifier: GPL-3.0-only
#include "MIDIIngress.h"
#include <cassert>
#include <cstdio>
#include <vector>

using namespace ob1::music;

int main()
{
    MIDIIngress ingress;
    std::vector<MIDIMessage> messages;
    auto sink = [&](uint32_t status, uint32_t a, uint32_t b) {
        messages.push_back({uint8_t(status), uint8_t(a), uint8_t(b)});
        return true;
    };
    const auto a = ingress.open(), b = ingress.open();
    assert(a && b && a != b);
    assert(!ingress.contains(0) && !ingress.close(0));
    assert(!ingress.input(0, 0x90, sink));
    assert(ingress.input(a, 0x90, sink));
    assert(ingress.input(a, 60, sink));
    assert(ingress.input(b, 100, sink)); // No status from a leaks into b.
    assert(messages.empty());
    assert(ingress.input(b, 0xC2, sink));
    assert(ingress.input(b, 17, sink));
    assert(ingress.input(a, 0xF8, sink)); // Realtime preserves incomplete messages.
    assert(ingress.input(a, 100, sink));
    assert(messages.size() == 3 && messages[0].status == 0xC2 && messages[0].data1 == 17);
    assert(messages[1].status == 0xF8 && messages[2].status == 0x90 &&
           messages[2].data1 == 60 && messages[2].data2 == 100);
    assert(ingress.input(a, 64, sink) && ingress.input(a, 80, sink));
    assert(messages.back().status == 0x90 && messages.back().data1 == 64);
    assert(ingress.input(a, 67, sink) && ingress.input(a, 0xFE, sink) && ingress.input(a, 90, sink));
    assert(messages.back().data1 == 67 && messages.back().data2 == 90);
    assert(!ingress.input(a, 256, sink));
    assert(ingress.input(a, 0xF0, sink));
    const auto size = messages.size();
    for (const auto byte : {1, 2, 0xF7, 60, 100}) assert(ingress.input(a, byte, sink));
    assert(messages.size() == size);
    assert(ingress.input(a, 0xD1, sink) && ingress.input(a, 70, sink));
    assert(messages.back().status == 0xD1 && messages.back().data1 == 70 && !messages.back().data2);
    assert(ingress.input(a, 0x90, sink) && ingress.input(a, 60, sink));
    assert(ingress.close(a) && !ingress.close(a));
    const auto reopened = ingress.open();
    assert(reopened && reopened != a && reopened != b);
    assert(!ingress.input(a, 100, sink)); // Late callback cannot affect replacement.
    const auto count = messages.size();
    assert(ingress.input(reopened, 100, sink) && messages.size() == count);
    assert(ingress.input(b, 18, sink) && messages.back().status == 0xC2);
    assert(ingress.close(b) && ingress.close(reopened));
    uint32_t ids[MIDIIngress::capacity] {};
    for (auto& id : ids) { id = ingress.open(); assert(id); }
    assert(!ingress.open());
    assert(ingress.close(ids[17]));
    const auto replacement = ingress.open();
    assert(replacement > ids[MIDIIngress::capacity - 1]);
    assert(!ingress.contains(ids[17]) && ingress.contains(replacement));
    MIDIByteParser parser;
    uint32_t calls = 0;
    auto reject = [&](uint32_t, uint32_t, uint32_t) { ++calls; return false; };
    assert(parser.input(0x90, reject) && parser.input(60, reject));
    assert(!parser.input(100, reject) && calls == 1);
    assert(parser.input(64, sink) && parser.input(90, sink));
    assert(messages.back().data1 == 64 && messages.back().data2 == 90);
    std::puts("PASS MIDI ingress: independent running status/partial messages, realtime/SysEx, program/pressure, stale callback rejection, fresh reconnect identity/parser, bounded capacity and sink rejection");
}
