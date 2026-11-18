// SPDX-License-Identifier: GPL-3.0-only
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
}
