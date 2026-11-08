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
    TabModel(label: "Sound", icon: "speaker.wave.2.fill", view: .sound),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Starlane", icon: "sparkles", view: .starlane)
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
            case .home, .sound: return true
            case .focus: return false
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .overlay(alignment: .topTrailing) {
                        if tab.view == .starlane, (starlane.summary?.needs ?? 0) > 0 {
                            Circle()
                                .fill(NotchStyle.attention)
                                .frame(width: 7, height: 7)
                                .padding(.top, 3)
                                .padding(.trailing, 8)
                        }
                    }
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(NotchStyle.control)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(Color.clear)
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
