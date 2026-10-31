//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Devices", icon: "hifispeaker.2.fill", view: .devices),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Starlane", icon: "sparkles", view: .starlane),
    TabModel(label: "Focus", icon: "timer", view: .focus),
    TabModel(label: "Mixer", icon: "slider.horizontal.3", view: .mixer)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var starlane = StarlaneManager.shared
    @StateObject var shelf = ShelfStateViewModel.shared
    @Namespace var animation

    private var visibleTabs: [TabModel] {
        tabs.filter { tab in
            switch tab.view {
            case .shelf: return Defaults[.boringShelf] && (!shelf.isEmpty || coordinator.alwaysShowTabs)
            case .starlane: return starlane.summary != nil
            case .home, .devices, .focus, .mixer: return true
            }
        }
    }

    var body: some View {
        // With five or six they only fit beside the notch closer together
        let padding: CGFloat = visibleTabs.count > 5 ? 6 : visibleTabs.count > 4 ? 10 : 15
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, horizontalPadding: padding) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .overlay(alignment: .topTrailing) {
                        if tab.view == .starlane, (starlane.summary?.needs ?? 0) > 0 {
                            Circle()
                                .fill(.orange)
                                .frame(width: 7, height: 7)
                                .padding(.top, 3)
                                .padding(.trailing, 8)
                        }
                    }
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
