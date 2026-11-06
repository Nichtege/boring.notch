//
//  SoundView.swift
//  boringNotch
//
//  The Sound tab: on the left where something plays, on the right how loud each app is.
//

import SwiftUI

struct SoundView: View {
    @State private var equalizedApp: EqualizerView.App?

    /// Room for a cover, two lines and a play button
    private let devicesWidth: CGFloat = 260

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // An app's equalizer needs the whole width, so the devices step aside while it's open
            if equalizedApp == nil {
                MediaDevicesView()
                    .frame(width: devicesWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle()
                    .fill(NotchStyle.surface)
                    .frame(width: 1)
                    .padding(.vertical, 8)
            }
            // Stays the same view while the equalizer opens in it, so the Mixer keeps listening
            MixerView(equalizedApp: $equalizedApp)
        }
        .animation(.smooth(duration: 0.3), value: equalizedApp == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
