//
//  LocalDevVPNApp.swift
//  LocalDevVPN
//
//  Created by Stossy11 on 28/03/2025.
//

import SwiftUI

@main
struct LocalDevVPNApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }
    
    private func handleURL(_ url: URL) {
        guard url.scheme == "localdevvpn" else { return }
        
        let tunnelManager = TunnelManager.shared
        
        switch url.host {
        case "enable":
            tunnelManager.startVPN()
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let schemeParam = components.queryItems?.first(where: { $0.name == "scheme" })?.value {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let callbackURL = URL(string: "\(schemeParam)://")!
                    UIApplication.shared.open(callbackURL)
                }
            }
        case "restart":
            // A tunnel can look connected while its extension is gone (iOS ended it under memory pressure):
            // "enable" then does nothing. Stop it and start it again; with ?scheme=, go back to the caller
            // once the tunnel is up again (at most 10 s).
            let scheme = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "scheme" })?.value
            Task { @MainActor in
                _ = try? await tunnelManager.isVPNActive() // loads the manager on a cold launch
                tunnelManager.restartVPN()
                guard let scheme, let callbackURL = URL(string: "\(scheme)://") else { return }
                var sawDown = false
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if tunnelManager.tunnelStatus != .connected {
                        sawDown = true
                    } else if sawDown {
                        break
                    }
                }
                _ = await UIApplication.shared.open(callbackURL)
            }
        case "disable":
            tunnelManager.stopVPN()
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let schemeParam = components.queryItems?.first(where: { $0.name == "scheme" })?.value {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let callbackURL = URL(string: "\(schemeParam)://")!
                    UIApplication.shared.open(callbackURL)
                }
            }
        default:
            break
        }
    }
}
