//
//  VoxSignApp.swift
//  VoxSign
//
//  App entry point.
//

import SwiftUI

@main
struct VoxSignApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var settings = SettingsStore.shared
    #if canImport(Speech)
    @StateObject private var speech = SpeechRecognizer.shared
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                #if canImport(Speech)
                .environmentObject(speech)
                #endif
                .onAppear {
                    #if canImport(Speech)
                    speech.requestAuthorization()
                    #endif
                    // Background capability: request notification permission and flush the offline queue on launch.
                    NotificationService.shared.requestAuthorization()
                    Task { await model.flushQueue() }
                    // Connectivity probe on launch (the top capsule lights up immediately).
                    ConnectivityService.shared.start()
                }
        }
    }
}
