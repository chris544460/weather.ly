//
//  Weather_lyApp.swift
//  Weather.ly
//
//  Created by Christian Martinez on 4/19/25.
//

import SwiftUI

@main
struct Weather_lyApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
