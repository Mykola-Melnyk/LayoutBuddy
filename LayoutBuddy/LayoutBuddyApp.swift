//
//  LayoutBuddyApp.swift
//  LayoutBuddy
//
//  Created by Mykola Melnyk on 10.08.2025.
//

import SwiftUI

@main
struct LayoutBuddyApp: App {
    // This line guarantees your AppDelegate is created and used.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window; just a placeholder Settings scene.
        Settings { EmptyView() }
    }
}
