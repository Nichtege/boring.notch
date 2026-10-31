//
//  AppVolumeRender.swift
//  boringNotch
//
//  What the audio thread does for the per-app volumes and equalizers: the tap's sound to the output, times the
//  gain, through the filters.
//  This runs in real time, so no allocation, locks, Swift concurrency, logging or Objective-C in here.
//

import CoreAudio
import Foundation

let equalizerFrequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

/// Where everything of the equalizer sits in its one block of memory: two sets of where the filters are headed,
/// where they are, and what they remember per channel. In Double, as a Float can't hold a filter this low steady.
enum EqualizerLayout {
    @inline(__always) static var bands: Int { 10 }
    @inline(__always) static var coefficientsPerBand: Int { 5 }
    @inline(__always) static var perSet: Int { bands * coefficientsPerBand }
    @inline(__always) static var current: Int { perSet * 2 }
    @inline(__always) static var memory: Int { current + perSet }
    @inline(__always) static var memoryPerChannel: Int { bands * 2 }
    @inline(__always) static var size: Int { memory + memoryPerChannel * 2 }
}

/// A filter per band that leaves the sound as it is when there's nothing to do. Not for the audio thread.
/// The filters are the peaking ones of the Audio EQ Cookbook, an octave wide like the bands are apart.
func fillEqualizerCoefficients(_ destination: UnsafeMutablePointer<Double>, bands: [Float], sampleRate: Double) {
    let q = 1.41
    for band in 0..<EqualizerLayout.bands {
        let coefficients = destination + band * EqualizerLayout.coefficientsPerBand
        let gain = band < bands.count ? Double(bands[band]) : 0
        let frequency = equalizerFrequencies[band]
        // AirPods in a call run so low that the highest bands don't exist
        guard gain.magnitude >= 0.05, frequency < sampleRate * 0.45 else {
            coefficients.update(repeating: 0, count: EqualizerLayout.coefficientsPerBand)
            coefficients[0] = 1
            continue
        }
        let level = pow(10, gain / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let a0 = 1 + alpha / level
        coefficients[0] = (1 + alpha * level) / a0
        coefficients[1] = -2 * cos(omega) / a0
        coefficients[2] = (1 - alpha * level) / a0
        coefficients[3] = coefficients[1]
        coefficients[4] = (1 - alpha / level) / a0
    }
}

/// Plain memory the audio thread can read without a lock or a retain.
struct AppVolumeRenderState {
    /// Where the gain is headed. Only the main thread writes it.
    var target: Float
    /// Where the gain is. It starts in silence.
    var current: Float = 0
    /// How far the gain may move per frame.
    var maxStepPerFrame: Float = 1
    /// How many inputs the output device brings along. Anything after those is the tap.
    var deviceInputs = 0
    /// Goes up with every pass, so whoever watches can tell it still runs.
    var passes: UInt32 = 0
    /// Laid out as in EqualizerLayout. Without it the sound only gets the gain.
    var equalizer: UnsafeMutablePointer<Double>?
    /// Which of the two sets the filters are headed for. The other one is free to be filled, then this switches.
    var equalizerTargets = 0
}

/// An AudioBufferList by hand, as Swift's wrapper for it goes through the Swift runtime on every access.
private struct RenderBuffers {
    let count: Int
    let buffers: UnsafePointer<AudioBuffer>

    @inline(__always)
    init(_ list: UnsafePointer<AudioBufferList>) {
        count = Int(list.pointee.mNumberBuffers)
        buffers = (UnsafeRawPointer(list) + MemoryLayout<AudioBuffer>.alignment).assumingMemoryBound(to: AudioBuffer.self)
    }
}

private struct RenderChannel {
    let samples: UnsafePointer<Float>
    let stride: Int
    let frames: Int
}

@inline(__always)
private func channel(_ wanted: Int, of list: RenderBuffers, from first: Int) -> RenderChannel? {
    var remaining = wanted
    var index = first
    while index < list.count {
        let buffer = list.buffers[index]
        let channels = Int(buffer.mNumberChannels)
        if remaining < channels {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            return RenderChannel(samples: data + remaining, stride: channels, frames: Int(buffer.mDataByteSize) / 4 / channels)
        }
        remaining -= channels
        index += 1
    }
    return nil
}

/// A step towards where the filters are headed, as a jump would click. Says whether they do anything at all.
@inline(__always)
private func settleEqualizer(_ memory: UnsafeMutablePointer<Double>, targets: Int) -> Bool {
    let headed = memory + targets * EqualizerLayout.perSet
    let current = memory + EqualizerLayout.current
    var isActive = false
    for index in 0..<EqualizerLayout.perSet {
        let distance = headed[index] - current[index]
        current[index] = distance.magnitude < 1e-6 ? headed[index] : current[index] + distance * 0.3
        if current[index] != (index % EqualizerLayout.coefficientsPerBand == 0 ? 1 : 0) {
            isActive = true
        }
    }
    if !isActive {
        (memory + EqualizerLayout.memory).update(repeating: 0, count: EqualizerLayout.memoryPerChannel * 2)
    }
    return isActive
}

/// Peaks a boost took over the top are bent back under it instead of being cut off.
@inline(__always)
private func limited(_ sample: Double) -> Float {
    let knee = 0.9
    let size = sample.magnitude
    guard size > knee else { return Float(sample) }
    let over = (size - knee) / (1 - knee)
    let bent = knee + (1 - knee) * over / (1 + over)
    return Float(sample < 0 ? -bent : bent)
}

@inline(__always)
private func equalize(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, coefficients: UnsafePointer<Double>, memory: UnsafeMutablePointer<Double>) {
    for frame in 0..<frames {
        var sample = Double(samples[frame * stride])
        for band in 0..<EqualizerLayout.bands {
            let filter = coefficients + band * EqualizerLayout.coefficientsPerBand
            let state = memory + band * 2
            let filtered = filter[0] * sample + state[0]
            state[0] = filter[1] * sample - filter[3] * filtered + state[1]
            state[1] = filter[2] * sample - filter[4] * filtered
            sample = filtered
        }
        samples[frame * stride] = limited(sample)
    }
}

func renderAppVolume(
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>,
    state: UnsafeMutablePointer<AppVolumeRenderState>
) {
    let inputs = RenderBuffers(input)
    let outputs = RenderBuffers(output)

    // The tap is the last two channels: a device with inputs of its own has those first. Without a tap
    // there's only that device's microphone, which must not end up in the output.
    var firstInput = inputs.count
    var inputChannels = 0
    while firstInput > state.pointee.deviceInputs && inputChannels < 2 {
        firstInput -= 1
        inputChannels += Int(inputs.buffers[firstInput].mNumberChannels)
    }

    var outputChannels = 0
    var frames = 0
    for index in 0..<outputs.count {
        let channels = Int(outputs.buffers[index].mNumberChannels)
        outputChannels += channels
        if channels > 0 {
            frames = max(frames, Int(outputs.buffers[index].mDataByteSize) / 4 / channels)
        }
    }

    // One straight line per buffer, so moving the slider doesn't click
    let start = state.pointee.current
    let target = state.pointee.target
    let distance = target - start
    let reach = state.pointee.maxStepPerFrame * Float(frames)
    let end = distance.magnitude <= reach ? target : start + (distance > 0 ? reach : -reach)
    let step = frames > 0 ? (end - start) / Float(frames) : 0

    var isEqualizing = false
    if let equalizer = state.pointee.equalizer {
        isEqualizing = settleEqualizer(equalizer, targets: state.pointee.equalizerTargets)
    }

    var outputChannel = 0
    for index in 0..<outputs.count {
        let buffer = outputs.buffers[index]
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
            outputChannel += channels
            continue
        }
        let bufferFrames = Int(buffer.mDataByteSize) / 4 / channels

        for offset in 0..<channels {
            let destination = data + offset
            var written = 0

            // AirPods in a call have one channel, and neither side of the stereo may get lost
            if outputChannels == 1, inputChannels >= 2,
               let left = channel(0, of: inputs, from: firstInput),
               let right = channel(1, of: inputs, from: firstInput) {
                written = min(bufferFrames, min(left.frames, right.frames))
                for frame in 0..<written {
                    let mixed = (left.samples[frame * left.stride] + right.samples[frame * right.stride]) * 0.5
                    destination[frame * channels] = mixed * (start + step * Float(frame + 1))
                }
            } else if let source = channel(inputChannels == 1 ? 0 : outputChannel, of: inputs, from: firstInput) {
                written = min(bufferFrames, source.frames)
                for frame in 0..<written {
                    destination[frame * channels] = source.samples[frame * source.stride] * (start + step * Float(frame + 1))
                }
            }

            if isEqualizing, written > 0, outputChannel < 2, let equalizer = state.pointee.equalizer {
                equalize(
                    destination, stride: channels, frames: written,
                    coefficients: equalizer + EqualizerLayout.current,
                    memory: equalizer + EqualizerLayout.memory + outputChannel * EqualizerLayout.memoryPerChannel
                )
            }

            var frame = written
            while frame < bufferFrames {
                destination[frame * channels] = 0
                frame += 1
            }
            outputChannel += 1
        }
    }

    state.pointee.current = end
    state.pointee.passes &+= 1
}
