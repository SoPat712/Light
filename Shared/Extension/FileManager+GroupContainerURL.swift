//
//  FileManager+GroupContainerURL.swift
//  Iron
//
//  Created by Karim Abou Zeid on 06.12.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

extension FileManager {
    static var appGroupIdentifier = "group.com.kabouzeid.Iron"
    
    var appGroupContainerURL: URL {
        Self.cachedAppGroupContainerURL
    }

    private static let cachedAppGroupContainerURL: URL = {
        let manager = FileManager.default
        if let containerURL = manager.containerURL(forSecurityApplicationGroupIdentifier: FileManager.appGroupIdentifier) {
            return containerURL
        }

        #if DEBUG
        // Personal Team and simulator builds cannot always carry App Group entitlements.
        // Keep development data inside the app sandbox while production builds continue to
        // require the configured shared container for widgets and extensions.
        let fallbackURL = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Development App Group", isDirectory: true)
            .appendingPathComponent(FileManager.appGroupIdentifier, isDirectory: true)
        do {
            try manager.createDirectory(at: fallbackURL, withIntermediateDirectories: true)
            return fallbackURL
        } catch {
            fatalError("development shared container could not be created: \(error)")
        }
        #else
        fatalError("shared container could not be created")
        #endif
    }()
    
    var appGroupContainerApplicationSupportURL: URL {
        Self.cachedAppGroupContainerApplicationSupportURL
    }

    private static let cachedAppGroupContainerApplicationSupportURL: URL = {
        let directory = cachedAppGroupContainerURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
        
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("could not create \(directory)")
        }
        
        return directory
    }()
}
