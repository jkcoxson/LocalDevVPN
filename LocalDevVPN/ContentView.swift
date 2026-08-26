//
//  ContentView.swift
//  LocalDevVPN
//
//  Created by Stossy11 on 28/03/2025.
//

import Foundation
import NetworkExtension
import SwiftUI

import NavigationBackport

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var tunnelBundleID: String { bundleIdentifier!.appending(".TunnelProv") }
}

// MARK: - Logging Utility

class VPNLogger: ObservableObject {
    @Published var logs: [String] = []

    static var shared = VPNLogger()

    private init() {}

    func log(_ message: Any, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
            let fileName = (file as NSString).lastPathComponent
            print("[\(fileName):\(line)] \(function): \(message)")
        #endif

        logs.append("\(message)")
    }
}

// MARK: - Tunnel Manager

struct TunnelAddresses {
    let interfaceIP: String
    let peerIP: String
}

class TunnelManager: ObservableObject {
    @Published var hasLocalDeviceSupport = false
    @Published var tunnelStatus: TunnelStatus = .disconnected

    static var shared = TunnelManager()

    @Published var waitingOnSettings: Bool = false
    @Published var vpnManager: NETunnelProviderManager?
    private var vpnObserver: NSObjectProtocol?
    private var isProcessingStatusChange = false
    private var pendingStartAddresses: TunnelAddresses?
    private let isSimulator: Bool = {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }()

    private var tunnelIfaceIP: String {
        UserDefaults.standard.string(forKey: "TunnelIfaceIP") ?? TunnelConstants.defaultIfaceIP
    }

    private var tunnelPeerIP: String {
        UserDefaults.standard.string(forKey: "TunnelPeerIP") ?? TunnelConstants.defaultPeerIP
    }

    var configuredAddresses: TunnelAddresses {
        TunnelAddresses(interfaceIP: tunnelIfaceIP, peerIP: tunnelPeerIP)
    }

    private var tunnelBundleId: String {
        Bundle.main.bundleIdentifier!.appending(".TunnelProv")
    }

    private func persistTunnelAddresses(in manager: NETunnelProviderManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            VPNLogger.shared.log("Cannot persist tunnel addresses: invalid protocol configuration")
            return false
        }

        var providerConfiguration = proto.providerConfiguration ?? [:]
        providerConfiguration[TunnelConstants.ifaceIPConfigurationKey] = tunnelIfaceIP
        providerConfiguration[TunnelConstants.peerIPConfigurationKey] = tunnelPeerIP
        proto.providerConfiguration = providerConfiguration
        manager.protocolConfiguration = proto
        return true
    }

    enum TunnelStatus {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case error

        var color: Color {
            switch self {
            case .disconnected: return .gray
            case .connecting: return .orange
            case .connected: return .green
            case .disconnecting: return .orange
            case .error: return .red
            }
        }

        var systemImage: String {
            switch self {
            case .disconnected: return "network.slash"
            case .connecting: return "network.badge.shield.half.filled"
            case .connected: return "checkmark.shield.fill"
            case .disconnecting: return "network.badge.shield.half.filled"
            case .error: return "exclamationmark.shield.fill"
            }
        }

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .disconnected:
                return "disconnected"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            case .disconnecting:
                return "disconnecting"
            case .error:
                return "error"
            }
        }
    }

    private init() {
        if isSimulator {
        loadTunnelPreferences()
            VPNLogger.shared.log("Running on Simulator – VPN calls are mocked")
            DispatchQueue.main.async { [weak self] in
                self?.waitingOnSettings = true
            }
        } else {
            setupStatusObserver()
            loadTunnelPreferences()
        }
    }

    // MARK: - Private Methods

    private func loadTunnelPreferences() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if let error = error {
                    VPNLogger.shared.log("Error loading preferences: \(error.localizedDescription)")
                    self.tunnelStatus = .error
                    self.waitingOnSettings = true
                    return
                }

                self.hasLocalDeviceSupport = true
                self.waitingOnSettings = true

                if let managers = managers, !managers.isEmpty {
                    let stosManagers = managers.filter { manager in
                        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                            return false
                        }
                        return proto.providerBundleIdentifier == self.tunnelBundleId
                    }

                    if !stosManagers.isEmpty {
                        if stosManagers.count > 1 {
                            self.cleanupDuplicateManagers(stosManagers)
                        } else if let manager = stosManagers.first {
                            self.vpnManager = manager
                            let currentStatus = manager.connection.status
                            VPNLogger.shared.log("Loaded existing LocalDevVPN tunnel configuration with status: \(currentStatus.rawValue)")
                            self.updateTunnelStatus(from: currentStatus)
                        }
                    } else {
                        VPNLogger.shared.log("No LocalDevVPN tunnel configuration found")
                    }
                } else {
                    VPNLogger.shared.log("No existing tunnel configurations found")
                }
            }
        }
    }

    private func cleanupDuplicateManagers(_ managers: [NETunnelProviderManager]) {
        VPNLogger.shared.log("Found \(managers.count) LocalDevVPN configurations. Cleaning up duplicates...")

        let activeManager = managers.first {
            $0.connection.status == .connected || $0.connection.status == .connecting
        }

        let managerToKeep = activeManager ?? managers.first!

        DispatchQueue.main.async { [weak self] in
            self?.vpnManager = managerToKeep
            self?.updateTunnelStatus(from: managerToKeep.connection.status)
        }

        for manager in managers where manager != managerToKeep {
            manager.removeFromPreferences { error in
                if let error = error {
                    VPNLogger.shared.log("Error removing duplicate VPN: \(error.localizedDescription)")
                } else {
                    VPNLogger.shared.log("Successfully removed duplicate VPN configuration")
                }
            }
        }
    }

    private func setupStatusObserver() {
        vpnObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let connection = notification.object as? NEVPNConnection else { return }

            VPNLogger.shared.log("VPN Status notification received: \(connection.status.rawValue)")

            // Update status immediately if it's our manager
            if let manager = self.vpnManager, connection == manager.connection {
                self.updateTunnelStatus(from: connection.status)
            }

            self.handleVPNStatusChange(notification: notification)
        }
    }

    private func updateTunnelStatus(from connectionStatus: NEVPNStatus) {
        let newStatus: TunnelStatus
        switch connectionStatus {
        case .invalid, .disconnected:
            newStatus = .disconnected
        case .connecting:
            newStatus = .connecting
        case .connected:
            newStatus = .connected
        case .disconnecting:
            newStatus = .disconnecting
        case .reasserting:
            newStatus = .connecting
        @unknown default:
            newStatus = .error
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.tunnelStatus != newStatus {
                VPNLogger.shared.log("LocalDevVPN status updated from \(self.tunnelStatus) to \(newStatus)")
            }
            self.tunnelStatus = newStatus
        }
    }

    private func createLocalDevVPNConfiguration(completion: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else {
                completion(nil)
                return
            }

            if let error = error {
                VPNLogger.shared.log("Error checking existing VPN configurations: \(error.localizedDescription)")
                completion(nil)
                return
            }

            if let managers = managers {
                let stosManagers = managers.filter { manager in
                    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                        return false
                    }
                    return proto.providerBundleIdentifier == self.tunnelBundleId
                }

                if let existingManager = stosManagers.first {
                    VPNLogger.shared.log("Found existing LocalDevVPN configuration, using it instead of creating new one")
                    completion(existingManager)
                    return
                }
            }

            let manager = NETunnelProviderManager()
            manager.localizedDescription = "LocalDevVPN"

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleId
            proto.serverAddress = "LocalDevVPN's Local Network Tunnel"
            proto.providerConfiguration = [
                TunnelConstants.ifaceIPConfigurationKey: self.tunnelIfaceIP,
                TunnelConstants.peerIPConfigurationKey: self.tunnelPeerIP,
            ]
            manager.protocolConfiguration = proto

            let onDemandRule = NEOnDemandRuleEvaluateConnection()
            onDemandRule.interfaceTypeMatch = .any
            onDemandRule.connectionRules = [NEEvaluateConnectionRule(
                matchDomains: [self.tunnelIfaceIP, self.tunnelPeerIP],
                andAction: .connectIfNeeded
            )]

            manager.onDemandRules = [onDemandRule]
            manager.isOnDemandEnabled = true
            manager.isEnabled = true

            manager.saveToPreferences { error in
                DispatchQueue.main.async {
                    if let error = error {
                        VPNLogger.shared.log("Error creating LocalDevVPN configuration: \(error.localizedDescription)")
                        completion(nil)
                        return
                    }

                    VPNLogger.shared.log("LocalDevVPN configuration created successfully")
                    completion(manager)
                }
            }
        }
    }

    private func getActiveVPNManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                VPNLogger.shared.log("Error loading VPN configurations: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let managers = managers else {
                completion(nil)
                return
            }

            let activeManager = managers.first { manager in
                manager.connection.status == .connected || manager.connection.status == .connecting
            }

            completion(activeManager)
        }
    }

    // MARK: - Public Methods

    func toggleVPNConnection() {
        if tunnelStatus == .connected || tunnelStatus == .connecting {
            stopVPN()
        } else {
            startVPN()
        }
    }

    @MainActor
    func isVPNActive() async throws -> Bool {
        if isSimulator {
            return tunnelStatus == .connected || tunnelStatus == .connecting
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let localManagers = managers.filter { manager in
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
            return proto?.providerBundleIdentifier == tunnelBundleId
        }
        let manager = localManagers.first { manager in
            let status = manager.connection.status
            return status == .connected || status == .connecting || status == .reasserting
        } ?? localManagers.first

        vpnManager = manager
        guard let manager = manager else {
            tunnelStatus = .disconnected
            return false
        }

        updateTunnelStatus(from: manager.connection.status)
        let status = manager.connection.status
        return status == .connected || status == .connecting || status == .reasserting
    }

    func startVPN(temporaryAddresses: TunnelAddresses? = nil) {
        if isSimulator {
            simulateStartVPN()
            return
        }

        if let manager = vpnManager {
            let currentStatus = manager.connection.status
            VPNLogger.shared.log("Current manager status: \(currentStatus.rawValue)")

            if currentStatus == .connected {
                VPNLogger.shared.log("VPN already connected, updating UI")
                DispatchQueue.main.async { [weak self] in
                    self?.tunnelStatus = .connected
                }
                return
            }

            if currentStatus == .connecting {
                VPNLogger.shared.log("VPN already connecting, updating UI")
                DispatchQueue.main.async { [weak self] in
                    self?.tunnelStatus = .connecting
                }
                return
            }
        }

        getActiveVPNManager { [weak self] activeManager in
            guard let self = self else { return }

            if let activeManager = activeManager,
               (activeManager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier != self.tunnelBundleId
            {
                VPNLogger.shared.log("Disconnecting existing VPN connection before starting LocalDevVPN")

                self.pendingStartAddresses = temporaryAddresses
                UserDefaults.standard.set(true, forKey: "ShouldStartLocalDevVPNAfterDisconnect")
                activeManager.connection.stopVPNTunnel()
                return
            }

            self.initializeAndStartLocalDevVPN(temporaryAddresses: temporaryAddresses)
        }
    }

    private func initializeAndStartLocalDevVPN(temporaryAddresses: TunnelAddresses?) {
        if let manager = vpnManager {
            manager.loadFromPreferences { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    VPNLogger.shared.log("Error reloading manager: \(error.localizedDescription)")
                    self.createAndStartVPN(temporaryAddresses: temporaryAddresses)
                    return
                }

                self.startExistingVPN(manager: manager, temporaryAddresses: temporaryAddresses)
            }
        } else {
            createAndStartVPN(temporaryAddresses: temporaryAddresses)
        }
    }

    private func createAndStartVPN(temporaryAddresses: TunnelAddresses?) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }

            if let error = error {
                VPNLogger.shared.log("Error reloading VPN configurations: \(error.localizedDescription)")
            }

            if let managers = managers {
                let stosManagers = managers.filter { manager in
                    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                        return false
                    }
                    return proto.providerBundleIdentifier == self.tunnelBundleId
                }

                if !stosManagers.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.vpnManager = stosManagers.first
                    }

                    if stosManagers.count > 1 {
                        self.cleanupDuplicateManagers(stosManagers)
                    }

                    if let manager = stosManagers.first {
                        self.startExistingVPN(manager: manager, temporaryAddresses: temporaryAddresses)
                    }
                    return
                }
            }

            self.createLocalDevVPNConfiguration { [weak self] manager in
                guard let self = self, let manager = manager else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.vpnManager = manager
                }
                self.startExistingVPN(manager: manager, temporaryAddresses: temporaryAddresses)
            }
        }
    }

    private func startExistingVPN(
        manager: NETunnelProviderManager,
        temporaryAddresses: TunnelAddresses?
    ) {
        // First check the actual current status
        let currentStatus = manager.connection.status
        VPNLogger.shared.log("Current VPN status before start attempt: \(currentStatus.rawValue)")

        if currentStatus == .connected {
            VPNLogger.shared.log("LocalDevVPN tunnel is already connected")
            DispatchQueue.main.async { [weak self] in
                self?.tunnelStatus = .connected
            }
            return
        }

        if currentStatus == .connecting {
            VPNLogger.shared.log("LocalDevVPN tunnel is already connecting")
            DispatchQueue.main.async { [weak self] in
                self?.tunnelStatus = .connecting
            }
            return
        }

        manager.isEnabled = true
        manager.saveToPreferences { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                VPNLogger.shared.log("Error saving preferences: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.tunnelStatus = .error
                }
                return
            }

            manager.loadFromPreferences { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    VPNLogger.shared.log("Error reloading preferences: \(error.localizedDescription)")
                    DispatchQueue.main.async { [weak self] in
                        self?.tunnelStatus = .error
                    }
                    return
                }

                // Check status again after reload
                let statusAfterReload = manager.connection.status
                VPNLogger.shared.log("VPN status after reload: \(statusAfterReload.rawValue)")

                if statusAfterReload == .connected {
                    VPNLogger.shared.log("VPN is already connected after reload")
                    DispatchQueue.main.async { [weak self] in
                        self?.tunnelStatus = .connected
                    }
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    self?.tunnelStatus = .connecting
                }

                let addresses = temporaryAddresses ?? self.configuredAddresses
                let options: [String: NSObject] = [
                    TunnelConstants.ifaceIPConfigurationKey: addresses.interfaceIP as NSObject,
                    TunnelConstants.peerIPConfigurationKey: addresses.peerIP as NSObject,
                ]

                do {
                    try manager.connection.startVPNTunnel(options: options)
                    VPNLogger.shared.log("LocalDevVPN tunnel start initiated")
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.tunnelStatus = .error
                    }
                    VPNLogger.shared.log("Failed to start LocalDevVPN tunnel: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopVPN() {
        pendingStartAddresses = nil
        UserDefaults.standard.removeObject(forKey: "ShouldStartLocalDevVPNAfterDisconnect")

        if isSimulator {
            simulateStopVPN()
            return
        }

        guard let manager = vpnManager else {
            VPNLogger.shared.log("No VPN manager available to stop")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.tunnelStatus = .disconnecting
        }

        manager.connection.stopVPNTunnel()
        VPNLogger.shared.log("LocalDevVPN tunnel stop initiated")
    }

    func updateConfigAndRestart(shouldRestart: Bool) {
        if isSimulator { return }
        
        guard let manager = vpnManager else { return }
        
        manager.loadFromPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                VPNLogger.shared.log("Error loading preferences for update: \(error.localizedDescription)")
                return
            }

            guard self.persistTunnelAddresses(in: manager) else { return }
            
            let onDemandRule = NEOnDemandRuleEvaluateConnection()
            onDemandRule.interfaceTypeMatch = .any
            onDemandRule.connectionRules = [NEEvaluateConnectionRule(
                matchDomains: [self.tunnelIfaceIP, self.tunnelPeerIP],
                andAction: .connectIfNeeded
            )]
            manager.onDemandRules = [onDemandRule]
            manager.isOnDemandEnabled = true
            manager.isEnabled = true
            
            manager.saveToPreferences { [weak self] error in
                guard self != nil else { return }
                if let error = error {
                    VPNLogger.shared.log("Error saving updated preferences: \(error.localizedDescription)")
                    return
                }
                
                VPNLogger.shared.log("LocalDevVPN configuration updated successfully in preferences")
                
                if shouldRestart {
                    VPNLogger.shared.log("Restarting LocalDevVPN tunnel to apply new configuration...")
                    self?.pendingStartAddresses = nil
                    UserDefaults.standard.set(true, forKey: "ShouldStartLocalDevVPNAfterDisconnect")
                    manager.connection.stopVPNTunnel()
                }
            }
        }
    }

    func handleVPNStatusChange(notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }

        VPNLogger.shared.log("Handling VPN status change: \(connection.status.rawValue)")

        // Always update status if it's our manager's connection
        if let manager = vpnManager, connection == manager.connection {
            VPNLogger.shared.log("Status change is for our LocalDevVPN manager")
            updateTunnelStatus(from: connection.status)
        }

        if connection.status == .disconnected &&
            UserDefaults.standard.bool(forKey: "ShouldStartLocalDevVPNAfterDisconnect")
        {
            UserDefaults.standard.removeObject(forKey: "ShouldStartLocalDevVPNAfterDisconnect")
            let temporaryAddresses = pendingStartAddresses
            pendingStartAddresses = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.initializeAndStartLocalDevVPN(temporaryAddresses: temporaryAddresses)
            }
            return
        }

        // Prevent recursive calls when checking for duplicates
        guard !isProcessingStatusChange else { return }
        isProcessingStatusChange = true

        // Check for duplicates asynchronously without blocking
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
                guard let self = self, let managers = managers, !managers.isEmpty else {
                    DispatchQueue.main.async { [weak self] in
                        self?.isProcessingStatusChange = false
                    }
                    return
                }

                let stosManagers = managers.filter { manager in
                    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                        return false
                    }
                    return proto.providerBundleIdentifier == self.tunnelBundleId
                }

                if stosManagers.count > 1 {
                    DispatchQueue.main.async { [weak self] in
                        self?.cleanupDuplicateManagers(stosManagers)
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    self?.isProcessingStatusChange = false
                }
            }
        }
    }

    // MARK: - Cleanup Utilities

    func cleanupAllVPNConfigurations() {
        if isSimulator {
            VPNLogger.shared.log("Simulator cleanup skipped – no real VPN configurations to remove")
            return
        }

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }

            if let error = error {
                VPNLogger.shared.log("Error loading VPN configurations for cleanup: \(error.localizedDescription)")
                return
            }

            guard let managers = managers else { return }

            for manager in managers {
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                      proto.providerBundleIdentifier == self.tunnelBundleId
                else {
                    continue
                }

                if manager.connection.status == .connected || manager.connection.status == .connecting {
                    manager.connection.stopVPNTunnel()
                }

                manager.removeFromPreferences { error in
                    if let error = error {
                        VPNLogger.shared.log("Error removing VPN configuration: \(error.localizedDescription)")
                    } else {
                        VPNLogger.shared.log("Successfully removed VPN configuration")
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.vpnManager = nil
                self?.tunnelStatus = .disconnected
            }
        }
    }

    deinit {
        if let observer = vpnObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func simulateStartVPN() {
        VPNLogger.shared.log("Simulator: pretend to start VPN")
        DispatchQueue.main.async { [weak self] in
            self?.tunnelStatus = .connecting
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.tunnelStatus = .connected
            VPNLogger.shared.log("Simulator: VPN marked connected")
        }
    }

    private func simulateStopVPN() {
        VPNLogger.shared.log("Simulator: pretend to stop VPN")
        DispatchQueue.main.async { [weak self] in
            self?.tunnelStatus = .disconnecting
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.tunnelStatus = .disconnected
            VPNLogger.shared.log("Simulator: VPN marked disconnected")
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @State private var showSettings = false
    @State var tunnel = false
    @AppStorage("autoConnect") private var autoConnect = false
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NBNavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TitleWithSettingsRow(showSettings: $showSettings)

                    StatusOverviewCard()

                    ConnectivityControlsCard(
                        action: {
                            tunnelManager.tunnelStatus == .connected ? tunnelManager.stopVPN() : tunnelManager.startVPN()
                        }
                    )

                    if tunnelManager.tunnelStatus == .connected {
                        ConnectionStatsView()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .applyAdaptiveBounce()
            .background(backgroundColor.ignoresSafeArea())
            .navigationTitle("")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .tvOSNavigationBarTitleDisplayMode(.inline)
            .onChange(of: tunnelManager.waitingOnSettings) { finished in
                if tunnelManager.tunnelStatus != .connected && autoConnect && finished {
                    tunnelManager.startVPN()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $hasNotCompletedSetup) {
                SetupView()
            }
        }
    }

    private var backgroundColor: Color {
        #if os(tvOS)
            return colorScheme == .dark ? .black : Color(white: 0.94)
        #else
        if colorScheme == .dark {
            return Color(.systemBackground)
        } else {
            return Color(.systemGroupedBackground)
        }
        #endif
    }
}

struct TitleWithSettingsRow: View {
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("LocalDevVPN")
                .font(.largeTitle)
                .fontWeight(.bold)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gear")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.primary)
            }
            .accessibilityLabel(Text("settings"))
        }
        .padding(.top, 4)
    }
}

extension View {
    @ViewBuilder
    func tvOSNavigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(displayMode)
        #else
            self
        #endif
    }

    @ViewBuilder
    func applyAdaptiveBounce() -> some View {
        if #available(iOS 16.4, tvOS 16.4, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}

struct StatusOverviewCard: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @AppStorage("TunnelIfaceIP") private var tunnelIfaceIP = TunnelConstants.defaultIfaceIP

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("current_status")
                    .font(.headline)

                HStack(spacing: 18) {
                    StatusGlyphView()

                    Text(tunnelManager.tunnelStatus.localizedTitle)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Divider()

                Label {
                    Text(statusTip)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    private var statusTip: String {
        switch tunnelManager.tunnelStatus {
        case .connected:
            return String(format: NSLocalizedString("connected_to_ip", comment: ""), tunnelIfaceIP)
        case .connecting:
            return NSLocalizedString("ios_might_ask_you_to_allow_the_vpn", comment: "")
        case .disconnecting:
            return NSLocalizedString("disconnecting_safely", comment: "")
        case .error:
            return NSLocalizedString("open_settings_to_review_details", comment: "")
        default:
            return NSLocalizedString("tap_connect_to_create_the_tunnel", comment: "")
        }
    }
}

struct StatusGlyphView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @State private var ringScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(tunnelManager.tunnelStatus.color.opacity(0.25), lineWidth: 6)
                .scaleEffect(ringScale, anchor: .center)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: ringScale)

            Circle()
                .fill(tunnelManager.tunnelStatus.color.opacity(0.15))

            Image(systemName: tunnelManager.tunnelStatus.systemImage)
                .font(.title)
                .foregroundColor(tunnelManager.tunnelStatus.color)
        }
        .frame(width: 92, height: 92)
        .onAppear(perform: startPulse)
    }

    private func startPulse() {
        DispatchQueue.main.async {
            ringScale = 1.08
        }
    }
}

struct ConnectivityControlsCard: View {
    let action: () -> Void

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("connection")
                        .font(.headline)
                    Text("start_or_stop_the_secure_local_tunnel")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                ConnectionButton(action: action)
            }
        }
    }
}

struct ConnectionInfoRow: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.body)
                    .foregroundColor(.primary)
            }
            Spacer()
        }
    }
}

struct ConnectionButton: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack {
                Text(buttonText)
                    .font(.headline)
                    .fontWeight(.semibold)

                if tunnelManager.tunnelStatus == .connecting || tunnelManager.tunnelStatus == .disconnecting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.leading, 5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(buttonBackground)
            .foregroundColor(.white)
            .clipShape(Capsule())
            .shadow(color: shadowColor, radius: 10, x: 0, y: 5)
        }
        .disabled(tunnelManager.tunnelStatus == .connecting || tunnelManager.tunnelStatus == .disconnecting)
    }

    private var buttonText: String {
        switch tunnelManager.tunnelStatus {
        case .connected:
            return NSLocalizedString("disconnect", comment: "")
        case .connecting:
            return NSLocalizedString("connecting_ellipsis", comment: "")
        case .disconnecting:
            return NSLocalizedString("disconnecting_ellipsis", comment: "")
        default:
            return NSLocalizedString("connect", comment: "")
        }
    }

    private var buttonBackground: some View {
        Group {
            if tunnelManager.tunnelStatus == .connected {
                LinearGradient(
                    gradient: Gradient(colors: [Color.red.opacity(0.8), Color.red]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.5) : Color.black.opacity(0.15)
    }
}

struct ConnectionStatsView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @AppStorage("TunnelIfaceIP") private var tunnelIfaceIP = TunnelConstants.defaultIfaceIP
    @AppStorage("TunnelPeerIP") private var tunnelPeerIP = TunnelConstants.defaultPeerIP

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("session_details")
                        .font(.headline)
                    Text("live_stats_while_the_tunnel_is_connected")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Divider()

                Text("network_configuration")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ConnectionInfoRow(
                    title: "tunnel_ip",
                    value: tunnelIfaceIP,
                    icon: "point.3.filled.connected.trianglepath.dotted"
                )

                ConnectionInfoRow(
                    title: "device_ip",
                    value: tunnelPeerIP,
                    icon: "desktopcomputer"
                )
            }
        }
    }
}

struct StatItemView: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(value)
                .font(.headline)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardCard<Content: View>: View {
    private let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(borderColor)
            )
            .shadow(color: shadowColor, radius: 12, x: 0, y: 6)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var cardBackgroundColor: Color {
        #if os(tvOS)
            return colorScheme == .dark ? Color(white: 0.10) : .white
        #else
            return Color(.secondarySystemBackground)
        #endif
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.5) : Color.black.opacity(0.12)
    }
}

// MARK: - Updated SettingsView

enum SettingsAlert: Identifiable {
    case savePrompt
    case discardPrompt
    case fixErrors
    case networkWarning
    case restartApp

    var id: Int { hashValue }
}

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    @AppStorage("selectedLanguage") private var selectedLanguage = Locale.current.languageCode ?? "en"
    @AppStorage("TunnelIfaceIP") private var savedIfaceIP = TunnelConstants.defaultIfaceIP
    @AppStorage("TunnelPeerIP") private var savedPeerIP = TunnelConstants.defaultPeerIP
    @AppStorage("allowIntermediateAddresses") private var savedAllowIntermediate = TunnelConstants.defaultAllowIntermediateAddresses
    @AppStorage("autoConnect") private var autoConnect = false
    @AppStorage("shownTunnelAlert") private var shownTunnelAlert = false
    @StateObject private var tunnelManager = TunnelManager.shared
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true

    // Draft State (Edited in UI, only committed upon confirmation)
    @State private var draftIfaceIP = ""
    @State private var draftPeerIP = ""
    @State private var draftAllowIntermediate = TunnelConstants.defaultAllowIntermediateAddresses

    // Validation State
    @State private var ifaceError: String? = nil
    @State private var peerError: String? = nil
    @State private var pairError: String? = nil
    @State private var ifaceWarnings: [String] = []
    @State private var peerWarnings: [String] = []

    // Alert State (Single active alert to prevent SwiftUI collisions)
    @State private var activeAlert: SettingsAlert? = nil

    private var isDirty: Bool {
        draftIfaceIP != savedIfaceIP ||
        draftPeerIP != savedPeerIP ||
        draftAllowIntermediate != savedAllowIntermediate
    }

    private var isValid: Bool {
        ifaceError == nil && peerError == nil && pairError == nil
    }

    private var effectiveIfaceIP: String {
        resolvedInput(draftIfaceIP, defaultValue: TunnelConstants.defaultIfaceIP)
    }

    private var effectivePeerIP: String {
        resolvedInput(draftPeerIP, defaultValue: TunnelConstants.defaultPeerIP)
    }

    var body: some View {
        NBNavigationStack {
            List {
                Section(header: Text("connection_settings")) {
                    Toggle("auto_connect_on_launch", isOn: $autoConnect)
                    NavigationLink(destination: ConnectionLogView()) {
                        Label("connection_logs", systemImage: "doc.text")
                    }
                }

                Section(
                    header: Text("network_configuration"),
                    footer: Text("allow_intermediate_addresses_desc")
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        networkConfigRow(
                            label: "tunnel_ip",
                            text: $draftIfaceIP,
                            defaultValue: TunnelConstants.defaultIfaceIP
                        )
                        if let error = ifaceError {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                        ForEach(ifaceWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        networkConfigRow(
                            label: "device_ip",
                            text: $draftPeerIP,
                            defaultValue: TunnelConstants.defaultPeerIP
                        )
                        if let error = peerError {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                        ForEach(peerWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    if let pairErr = pairError {
                        Text(pairErr)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }

                    Toggle("allow_intermediate_addresses", isOn: $draftAllowIntermediate)
                        .onChange(of: draftAllowIntermediate) { _ in
                            validateAll()
                        }
                }

                Section(header: Text("app_information")) {
                    Button {
                        UIApplication.shared.open(URL(string: "https://jkcoxson.com/cdn/LocalDevVPN/LocalDevVPNPrivacyPolicy.md")!, options: [:])
                    } label: {
                        Label("privacy_policy", systemImage: "lock.shield")
                    }
                    NavigationLink(destination: DataCollectionInfoView()) {
                        Label("data_collection_policy", systemImage: "hand.raised.slash")
                    }
                    HStack {
                        Text("app_version")
                        Spacer()
                        Text(Bundle.main.shortVersion)
                            .foregroundColor(.secondary)
                    }
                    NavigationLink(destination: HelpView()) {
                        Text("help_and_support")
                    }
                }

                Section(header: Text("language")) {
                    Picker("dropdown_language", selection: $selectedLanguage) {
                        Text("english").tag("en")
                        Text("spanish").tag("es")
                        Text("italian").tag("it")
                        Text("polish").tag("pl")
                        Text("korean").tag("ko")
                        Text("TChinese").tag("zh-Hant")
                        Text("french").tag("fr")
                        Text("japanese").tag("ja")

                    }
                    .onChange(of: selectedLanguage) { newValue in
                        let languageCode = newValue
                        LanguageManager.shared.updateLanguage(to: languageCode)
                        activeAlert = .restartApp
                    }
                }
            }
            .onAppear {
                draftIfaceIP = savedIfaceIP
                draftPeerIP = savedPeerIP
                draftAllowIntermediate = savedAllowIntermediate
                validateAll()
            }
            .navigationTitle(Text("settings"))
            .tvOSNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") {
                        if isDirty {
                            if isValid {
                                activeAlert = .savePrompt
                            } else {
                                activeAlert = .fixErrors
                            }
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel") {
                        if isDirty {
                            activeAlert = .discardPrompt
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .alert(item: $activeAlert) { alertType in
                switch alertType {
                case .savePrompt:
                    return Alert(
                        title: Text("Save Configuration Changes?"),
                        message: Text("Do you want to save and apply the new network configuration?"),
                        primaryButton: .default(Text("Save & Apply")) {
                            saveAndApply()
                        },
                        secondaryButton: .cancel(Text("cancel"))
                    )
                case .discardPrompt:
                    return Alert(
                        title: Text("Discard Changes?"),
                        message: Text("You have unsaved changes. Are you sure you want to discard them?"),
                        primaryButton: .destructive(Text("Discard")) {
                            dismiss()
                        },
                        secondaryButton: .cancel(Text("cancel"))
                    )
                case .fixErrors:
                    return Alert(
                        title: Text("Invalid Configuration"),
                        message: Text("Please resolve all configuration errors before saving."),
                        dismissButton: .default(Text("OK"))
                    )
                case .networkWarning:
                    return Alert(
                        title: Text("warning_alert"),
                        message: Text("warning_message"),
                        dismissButton: .cancel(Text("understand_button")) {
                            shownTunnelAlert = true
                            draftIfaceIP = TunnelConstants.defaultIfaceIP
                            draftPeerIP = TunnelConstants.defaultPeerIP
                            validateAll()
                        }
                    )
                case .restartApp:
                    return Alert(
                        title: Text("restart_title"),
                        message: Text("restart_message"),
                        dismissButton: .cancel(Text("understand_button"))
                    )
                }
            }
        }
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }

    private func saveAndApply() {
        savedIfaceIP = effectiveIfaceIP
        savedPeerIP = effectivePeerIP
        savedAllowIntermediate = draftAllowIntermediate

        let isRunning = tunnelManager.tunnelStatus == .connected || tunnelManager.tunnelStatus == .connecting
        tunnelManager.updateConfigAndRestart(shouldRestart: isRunning)
        dismiss()
    }

    private func validateAll() {
        ifaceError = nil
        peerError = nil
        pairError = nil
        ifaceWarnings = []
        peerWarnings = []

        do {
            let res = try CIDRValidator.shared.validateCIDR(
                effectiveIfaceIP,
                isRouteDestination: false,
                allowIntermediateAddresses: true,
                defaultPrefix: 24
            )
            ifaceWarnings = res.warnings
        } catch {
            ifaceError = error.localizedDescription
        }

        do {
            let res = try CIDRValidator.shared.validateCIDR(
                effectivePeerIP,
                isRouteDestination: true,
                allowIntermediateAddresses: draftAllowIntermediate,
                defaultPrefix: 24
            )
            peerWarnings = res.warnings
        } catch {
            peerError = error.localizedDescription
        }

        if ifaceError == nil && peerError == nil {
            do {
                _ = try CIDRValidator.shared.validatePair(
                    tunnelIfaceInput: effectiveIfaceIP,
                    tunnelPeerInput: effectivePeerIP,
                    allowIntermediateAddresses: draftAllowIntermediate
                )
            } catch {
                pairError = error.localizedDescription
            }
        }
    }

    private func resolvedInput(_ input: String, defaultValue: String) -> String {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedInput.isEmpty ? defaultValue : trimmedInput
    }

    private func networkConfigRow(
        label: LocalizedStringKey,
        text: Binding<String>,
        defaultValue: String
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(defaultValue, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.secondary)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityLabel(Text(label))
                .onChange(of: text.wrappedValue) { _ in
                    validateAll()
                    if !shownTunnelAlert {
                        activeAlert = .networkWarning
                    }
                }
        }
    }
}

// MARK: - New Data Collection Info View

struct DataCollectionInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("data_collection_policy_title")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.bottom, 10)

                GroupBox(label: Label("no_data_collection", systemImage: "hand.raised.slash").font(.headline)) {
                    Text("no_data_collection_description")
                        .padding(.vertical)
                }

                GroupBox(label: Label("local_processing_only", systemImage: "iphone").font(.headline)) {
                    Text("local_processing_only_description")
                        .padding(.vertical)
                }

                GroupBox(label: Label("no_third_party_sharing", systemImage: "person.2.slash").font(.headline)) {
                    Text("no_third_party_sharing_description")
                        .padding(.vertical)
                }

                GroupBox(label: Label("why_use_network_permissions", systemImage: "network").font(.headline)) {
                    Text("why_use_network_permissions_description")
                        .padding(.vertical)
                }

                GroupBox(label: Label("our_promise", systemImage: "checkmark.seal").font(.headline)) {
                    Text("our_promise_description")
                        .padding(.vertical)
                }
            }
            .padding()
        }
        .navigationTitle(Text("data_collection_policy_nav"))
        .tvOSNavigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionLogView: View {
    @StateObject var logger = VPNLogger.shared
    var body: some View {
        List(logger.logs, id: \.self) { log in
            Text(log)
                .font(.system(.body, design: .monospaced))
        }
        .navigationTitle(Text("logs_nav"))
        .tvOSNavigationBarTitleDisplayMode(.inline)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section(header: Text("faq_header")) {
                NavigationLink("faq_q1") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("faq_q1_a1")
                            .padding(.bottom, 10)
                        Text("faq_common_use_cases")
                            .fontWeight(.medium)
                        Text("faq_case1")
                        Text("faq_case2")
                        Text("faq_case3")
                        Text("faq_case4")
                    }
                    .padding()
                }
                NavigationLink("faq_q2") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("faq_q2_a1")
                            .padding(.bottom, 10)
                            .font(.headline)
                        Text("faq_q2_point1")
                        Text("faq_q2_point2")
                        Text("faq_q2_point3")
                        Text("faq_q2_point4")
                        Text("faq_q2_a2")
                            .padding(.top, 10)
                    }
                    .padding()
                }
                NavigationLink("faq_q3") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("faq_q3_a1")
                            .padding(.bottom, 10)
                        Text("faq_troubleshoot_header")
                            .font(.headline)
                        Text("faq_troubleshoot1")
                        Text("faq_troubleshoot2")
                        Text("faq_troubleshoot3")
                        Text("faq_troubleshoot4")
                    }
                    .padding()
                }
                NavigationLink("faq_q4") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("faq_q4_intro")
                            .font(.headline)
                            .padding(.bottom, 10)
                        Text("faq_q4_case1")
                        Text("faq_q4_case2")
                        Text("faq_q4_case3")
                        Text("faq_q4_case4")
                        Text("faq_q4_conclusion")
                            .padding(.top, 10)
                    }
                    .padding()
                }
            }
            Section(header: Text("business_model_header")) {
                NavigationLink("biz_q1") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("biz_q1_a1")
                            .padding(.bottom, 10)
                        Text("biz_key_points_header")
                            .font(.headline)
                        Text("biz_point1")
                        Text("biz_point2")
                        Text("biz_point3")
                        Text("biz_point4")
                        Text("biz_point5")
                    }
                    .padding()
                }
            }
            Section(header: Text("app_info_header")) {
                HStack {
                    Image(systemName: "exclamationmark.shield")
                    Text("requires_ios")
                }
                HStack {
                    Image(systemName: "lock.shield")
                    Text("uses_network_extension")
                }
            }
        }
        .navigationTitle(Text("help_and_support_nav"))
        .tvOSNavigationBarTitleDisplayMode(.inline)
    }
}

struct SetupView: View {
    @Environment(\.presentationMode) var presentationMode
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true
    @State private var currentPage = 0
    let pages = [
        SetupPage(
            title: "setup_welcome_title",
            description: "setup_welcome_description",
            imageName: "checkmark.shield.fill",
            details: "setup_welcome_details"
        ),
        SetupPage(
            title: "setup_why_title",
            description: "setup_why_description",
            imageName: "person.2.fill",
            details: "setup_why_details"
        ),
        SetupPage(
            title: "setup_easy_title",
            description: "setup_easy_description",
            imageName: "hand.tap.fill",
            details: "setup_easy_details"
        ),
        SetupPage(
            title: "setup_privacy_title",
            description: "setup_privacy_description",
            imageName: "lock.shield.fill",
            details: "setup_privacy_details"
        ),
    ]
    var body: some View {
        NBNavigationStack {
            VStack {
                TabView(selection: $currentPage) {
                    ForEach(0 ..< pages.count, id: \.self) { index in
                        SetupPageView(page: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                Spacer()
                if currentPage == pages.count - 1 {
                    Button {
                        hasNotCompletedSetup = false
                        dismiss()
                    } label: {
                        Text("setup_get_started")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                } else {
                    Button {
                        withAnimation { currentPage += 1 }
                    } label: {
                        Text("setup_next")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                }
            }
            .navigationTitle(Text("setup_nav"))
            .tvOSNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("setup_skip") { hasNotCompletedSetup = false; dismiss() }
                }
            }
        }
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}

struct SetupPage {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let imageName: String
    let details: LocalizedStringKey
}

struct SetupPageView: View {
    let page: SetupPage

    var body: some View {
        VStack(spacing: tvOSSpacing) {
            Image(systemName: page.imageName)
                .font(.system(size: tvOSImageSize))
                .foregroundColor(.blue)
                .padding(.top, tvOSTopPadding)

            Text(page.title)
                .font(tvOSTitleFont)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text(page.description)
                .font(tvOSDescriptionFont)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                Text(page.details)
                    .font(tvOSBodyFont)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Conditional sizes for tvOS

    private var tvOSImageSize: CGFloat {
        #if os(tvOS)
            return 60
        #else
            return 80
        #endif
    }

    private var tvOSTopPadding: CGFloat {
        #if os(tvOS)
            return 30
        #else
            return 50
        #endif
    }

    private var tvOSSpacing: CGFloat {
        #if os(tvOS)
            return 20
        #else
            return 30
        #endif
    }

    private var tvOSTitleFont: Font {
        #if os(tvOS)
            return .headline // .system(size: 35).bold()
        #else
            return .title
        #endif
    }

    private var tvOSDescriptionFont: Font {
        #if os(tvOS)
            return .subheadline
        #else
            return .headline
        #endif
    }

    private var tvOSBodyFont: Font {
        #if os(tvOS)
            return .system(size: 18).bold()
        #else
            return .body
        #endif
    }
}

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    @Published var currentLanguage: String = Locale.current.languageCode ?? "en"
    private let supportedLanguages = ["en", "es", "it", "pl", "ko", "zh-Hant", "fr"]

    func updateLanguage(to languageCode: String) {
        if supportedLanguages.contains(languageCode) {
            currentLanguage = languageCode
            UserDefaults.standard.set([languageCode], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        } else {
            currentLanguage = "en" // FALLBACK TO DEFAULT LANGUAGE
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
    }
}

#if os(tvOS)
    @ViewBuilder
    func GroupBox<Content: View>(
        label: some View,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(tvOS)
            tvOSGroupBox(label: {
                label
            }, content: content)
        #else
            SwiftUI.GroupBox(label: label, content: content)
        #endif
    }

    struct tvOSGroupBox<Label: View, Content: View>: View {
        @ViewBuilder let label: () -> Label
        @ViewBuilder let content: () -> Content

        init(
            @ViewBuilder label: @escaping () -> Label,
            @ViewBuilder content: @escaping () -> Content
        ) {
            self.label = label
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                label()
                    .font(.headline)

                content()
                    .padding(.top, 4)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator, lineWidth: 0.5)
            )
        }
    }
#endif

#Preview {
    ContentView()
}
