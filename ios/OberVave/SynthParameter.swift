// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func lfoRateText(_ value: Int) -> String {
    String(format: "%.2f Hz", ov_lfo_rate_hz(UInt32(max(0, min(127, value)))))
}

struct LFOModulationRoute: Identifiable {
    let id: String
    let destination: String
    let depth: Int
    var warning: String? = nil

    var text: String { "\(destination)  \(depth == 0 ? "OFF" : "\(depth)/127")" }

    static func routes(value: (SynthParameter) -> Int) -> [LFOModulationRoute] {
        func target(_ parameter: SynthParameter) -> String {
            ["OSC 1", "OSC 2", "OSC 1+2"][max(0, min(2, value(parameter)))]
        }
        let pwmTarget = value(.lfoPulseTarget)
        let silentPWM = (0...1).filter { oscillator in
            (pwmTarget == 2 || pwmTarget == oscillator) &&
                value(oscillator == 0 ? .osc1Wave : .osc2Wave) & 2 == 0
        }.map { "OSC \($0 + 1)" }
        return [
            .init(id: "pitch", destination: "LFO → \(target(.lfoPitchTarget)) PITCH", depth: value(.lfoPitch)),
            .init(id: "pwm", destination: "LFO → \(target(.lfoPulseTarget)) PWM", depth: value(.lfoPulseWidth),
                  warning: value(.lfoPulseWidth) > 0 && !silentPWM.isEmpty
                    ? "\(silentPWM.joined(separator: ", ")): enable PULSE wave for PWM" : nil),
            .init(id: "filter", destination: "LFO → FILTER CUTOFF", depth: value(.lfoFilter)),
            .init(id: "amp", destination: "LFO → VOLUME (TREMOLO)", depth: value(.lfoAmp)),
            .init(id: "wheel", destination: "CC1 → OSC 1+2 PITCH + CUTOFF",
                  depth: value(.legacyWheel) != 0 ? value(.modWheelDepth) : 0)
        ]
    }
}

enum SynthParameter: Int, CaseIterable {
    case osc1Wave, osc1PulseWidth, osc1Level, noise
    case osc2Wave, osc2PulseWidth, osc2Level, osc2Semitone
    case oscillatorSync, crossMod, envelopeToOsc2, osc2Fine
    case cutoff, resonance, filterEnvelopeAmount, keyTracking, filterType
    case drive, velocityToFilter, velocityToAmp
    case filterAttack, filterDecay, filterSustain, filterRelease
    case ampAttack, ampDecay, ampSustain, ampRelease
    case lfoShape, lfoRate, lfoDelay, lfoPhase
    case lfoPitch, lfoPulseWidth, lfoFilter, lfoAmp, lfoPitchTarget, lfoPulseTarget
    case voiceMode, unisonVoices, detune, glide
    case vintage, stereoSpread, bendRange, volume, modWheelDepth
    case arpMode, arpDivision, arpOctaves, arpGate, fmMorph
    case chorusRate, chorusDepth, chorusMix
    case delayTime, delayFeedback, delayTone, delayMix
    case reverbSize, reverbDamping, reverbPreDelay, reverbMix
    case arpLatch
    case arpVelocity
    case mod1Source, mod1Destination, mod1Amount
    case mod2Source, mod2Destination, mod2Amount
    case mod3Source, mod3Destination, mod3Amount
    case mod4Source, mod4Destination, mod4Amount
    case mod5Source, mod5Destination, mod5Amount
    case mod6Source, mod6Destination, mod6Amount
    case mod7Source, mod7Destination, mod7Amount
    case mod8Source, mod8Destination, mod8Amount
    case legacyWheel
    case ctl1Source, ctl1Target, ctl1Mode, ctl1Min, ctl1Max, ctl1Depth, ctl1Override
    case ctl2Source, ctl2Target, ctl2Mode, ctl2Min, ctl2Max, ctl2Depth, ctl2Override
    case ctl3Source, ctl3Target, ctl3Mode, ctl3Min, ctl3Max, ctl3Depth, ctl3Override
    case ctl4Source, ctl4Target, ctl4Mode, ctl4Min, ctl4Max, ctl4Depth, ctl4Override
    case ctl5Source, ctl5Target, ctl5Mode, ctl5Min, ctl5Max, ctl5Depth, ctl5Override
    case ctl6Source, ctl6Target, ctl6Mode, ctl6Min, ctl6Max, ctl6Depth, ctl6Override
    case ctl7Source, ctl7Target, ctl7Mode, ctl7Min, ctl7Max, ctl7Depth, ctl7Override
    case ctl8Source, ctl8Target, ctl8Mode, ctl8Min, ctl8Max, ctl8Depth, ctl8Override
    case ctl9Source, ctl9Target, ctl9Mode, ctl9Min, ctl9Max, ctl9Depth, ctl9Override
    case ctl10Source, ctl10Target, ctl10Mode, ctl10Min, ctl10Max, ctl10Depth, ctl10Override
    case ctl11Source, ctl11Target, ctl11Mode, ctl11Min, ctl11Max, ctl11Depth, ctl11Override
    case ctl12Source, ctl12Target, ctl12Mode, ctl12Min, ctl12Max, ctl12Depth, ctl12Override
    case ctl13Source, ctl13Target, ctl13Mode, ctl13Min, ctl13Max, ctl13Depth, ctl13Override
    case ctl14Source, ctl14Target, ctl14Mode, ctl14Min, ctl14Max, ctl14Depth, ctl14Override
    case ctl15Source, ctl15Target, ctl15Mode, ctl15Min, ctl15Max, ctl15Depth, ctl15Override
    case ctl16Source, ctl16Target, ctl16Mode, ctl16Min, ctl16Max, ctl16Depth, ctl16Override

    var audioUnitID: UInt32 { UInt32(rawValue < 65 ? rawValue : rawValue + 7) }
}

enum ModulationMatrix {
    static let sources = ["OFF", "LFO", "MOD WHEEL", "VELOCITY", "AFTERTOUCH", "FILTER ENV", "AMP ENV", "LFO × WHEEL"]
    static let destinations = ["OSC 1 PITCH", "OSC 2 PITCH", "OSC 1 PWM", "OSC 2 PWM", "CUTOFF", "RESONANCE", "VOLUME", "PAN"]
    static let ranges = ["±24 st", "±24 st", "±47% width", "±47% width", "±96 st", "±127", "±100% gain", "±full pan"]
    static func parameters(slot: Int) -> (source: SynthParameter, destination: SynthParameter, amount: SynthParameter) {
        let parameters = SynthParameter.allCases
        let index = SynthParameter.mod1Source.rawValue + slot * 3
        return (parameters[index], parameters[index + 1], parameters[index + 2])
    }
    static func amountText(_ raw: Int) -> String {
        String(format: "%+.1f%%", Double(raw - 64) * 100 / 64)
    }

    static func migrateLegacy(_ values: [Int], defaults: [Int]) -> [Int] {
        [65, 90].contains(values.count)
            ? values + defaults.dropFirst(values.count)
            : values
    }
}

enum ControllerRouting {
    static let sources = ["OFF"] + (0..<128).map { cc in
        switch cc {
        case 0: "CC 0 · BANK MSB"
        case 1: "CC 1 · MOD WHEEL"
        case 7: "CC 7 · VOLUME"
        case 32: "CC 32 · BANK LSB"
        case 64: "CC 64 · SUSTAIN"
        case 120: "CC 120 · ALL SOUND OFF"
        case 121: "CC 121 · RESET CONTROLLERS"
        case 123: "CC 123 · ALL NOTES OFF"
        default: "CC \(cc)"
        }
    } + ["PITCH BEND", "CHANNEL AFTERTOUCH", "POLY AFTERTOUCH"]
    static let targetNames = [
        "OSC 1 Wave", "OSC 1 Pulse Width", "OSC 1 Level", "Noise",
        "OSC 2 Wave", "OSC 2 Pulse Width", "OSC 2 Level", "OSC 2 Semitone",
        "Oscillator Sync", "Cross Mod", "Envelope to OSC 2", "OSC 2 Fine",
        "Filter Cutoff", "Filter Resonance", "Filter Envelope Amount", "Filter Key Tracking", "Filter Type",
        "Filter Drive", "Velocity to Filter", "Velocity to Amp",
        "Filter Attack", "Filter Decay", "Filter Sustain", "Filter Release",
        "Amp Attack", "Amp Decay", "Amp Sustain", "Amp Release",
        "LFO Shape", "LFO Rate", "LFO Delay", "LFO Phase",
        "LFO Pitch", "LFO Pulse Width", "LFO Filter", "LFO Amp", "LFO Pitch Target", "LFO PWM Target",
        "Voice Mode", "Unison Voices", "Detune", "Glide",
        "Vintage", "Stereo Spread", "Pitch Bend Range", "Patch Volume", "Mod Wheel Depth",
        "Arp Mode", "Arp Division", "Arp Octaves", "Arp Gate", "FM Morph",
        "Chorus Rate", "Chorus Depth", "Chorus Mix", "Delay Time", "Delay Feedback", "Delay Tone", "Delay Mix",
        "Reverb Size", "Reverb Damping", "Reverb Pre-delay", "Reverb Mix", "Arp Latch", "Arp Velocity"
    ]
    static func parameter(_ slot: Int, _ field: Int) -> SynthParameter {
        SynthParameter.allCases[SynthParameter.ctl1Source.rawValue + slot * 7 + field]
    }
}
