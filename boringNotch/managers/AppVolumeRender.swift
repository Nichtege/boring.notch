//
//  AppVolumeRender.swift
//  boringNotch
//
//  What the audio thread does for the per-app volumes: the tap's sound to the output, times the gain.
//  This runs in real time, so no allocation, locks, Swift concurrency, logging or Objective-C in here.
//

import CoreAudio

/// Plain memory the audio thread can read without a lock or a retain.
struct AppVolumeRenderState {
    /// Where the gain is headed. Only the main thread writes it.
    var target: Float
    /// Where the gain is. It starts in silence.
    var current: Float = 0
    /// How far the gain may move per frame.
    var maxStepPerFrame: Float = 1
    var didRender = false
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

func renderAppVolume(
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>,
    state: UnsafeMutablePointer<AppVolumeRenderState>
) {
    let inputs = RenderBuffers(input)
    let outputs = RenderBuffers(output)

    // The tap is the last two channels: a device with inputs of its own has those first
    var firstInput = inputs.count
    var inputChannels = 0
    while firstInput > 0 && inputChannels < 2 {
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

            var frame = written
            while frame < bufferFrames {
                destination[frame * channels] = 0
                frame += 1
            }
            outputChannel += 1
        }
    }

    state.pointee.current = end
    state.pointee.didRender = true
}
