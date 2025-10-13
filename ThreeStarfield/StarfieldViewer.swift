//
//  StarfieldViewer.swift
//  Three.js Starfield - iOS Port
//
//  A self-contained SceneKit-based 3D starfield viewer for iOS.
//  Drop this file into your Xcode project and use `StarfieldView` in SwiftUI.
//
//  Requirements:
//  - Add your `data.json` file to the app bundle (or load from URL)
//  - Import SceneKit and SwiftUI (for SwiftUI usage)
//  - iOS 15.0+ (for async/await; adjust if targeting older versions)
//

import Foundation
import SceneKit
import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#endif

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#endif

// MARK: - Data Model

/// Represents a single star from the catalog JSON file.
/// Matches the structure of items in the "stars" array in data.json.
struct Star: Codable, Identifiable {
    let id: UUID = UUID()
    let name: String
    let rightAscension: Double  // degrees
    let declination: Double     // degrees
    let distance: Double        // light years (or arbitrary units)
    let magnitude: Double       // stellar magnitude (lower = brighter)
    let color: String           // hex color string, e.g., "#ffffff"
    let type: String            // spectral type, e.g., "G2V"
    let temperature: Int        // Kelvin
    
    enum CodingKeys: String, CodingKey {
        case name, rightAscension, declination, distance, magnitude, color, type, temperature
    }
}

/// Container for the JSON root structure: { "stars": [...] }
struct StarCatalog: Codable {
    let stars: [Star]
}

// MARK: - Star Loader

/// Loads star data from a JSON file in the app bundle or from a remote URL.
class StarLoader {
    
    /// Load stars from a file in the app bundle.
    static func loadFromBundle(filename: String = "data.json") async throws -> [Star] {
        guard let url = Bundle.main.url(forResource: filename.replacingOccurrences(of: ".json", with: ""),
                                         withExtension: "json") else {
            throw NSError(domain: "StarLoader", code: 404, userInfo: [NSLocalizedDescriptionKey: "File \(filename) not found in bundle"])
        }
        return try await load(from: url)
    }
    
    /// Load stars from a given URL (bundle or remote).
    static func load(from url: URL) async throws -> [Star] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let catalog = try decoder.decode(StarCatalog.self, from: data)
        return catalog.stars
    }
}

// MARK: - Coordinate Conversion

/// Converts celestial coordinates (RA/Dec in degrees) and distance to 3D Cartesian coordinates.
/// Matches the Three.js `raDecToCartesian` function.
struct CoordinateConverter {
    
    /// Scale factor for visualization (adjust to fit scene nicely).
    static let distanceScale: Double = 2.0
    
    static func raDecToVector3(ra: Double, dec: Double, distance: Double) -> SCNVector3 {
        let raRad = ra * .pi / 180.0
        let decRad = dec * .pi / 180.0
        let scaledDistance = distance * distanceScale
        
        // Spherical to Cartesian:
        // x = r * cos(dec) * cos(ra)
        // y = r * cos(dec) * sin(ra)
        // z = r * sin(dec)
        let x = scaledDistance * cos(decRad) * cos(raRad)
        let y = scaledDistance * cos(decRad) * sin(raRad)
        let z = scaledDistance * sin(decRad)
        
        return SCNVector3(x, y, z)
    }
}

// MARK: - Star Sizing

/// Calculates visual size (radius) for a star based on its magnitude.
/// Matches the Three.js `getStarSize` function.
struct StarSizer {
    static func size(for magnitude: Double) -> CGFloat {
        // Invert magnitude (lower = brighter) and clamp to minimum 0.5
        return CGFloat(max(0.5, 5.0 - magnitude))
    }
}

// MARK: - Color Utilities

extension Color {
    /// Parse a hex color string (e.g., "#ffffff" or "ffffff") into Color.
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgb)
        
        let r, g, b: Double
        if hexString.count == 6 {
            r = Double((rgb >> 16) & 0xff) / 255.0
            g = Double((rgb >> 8) & 0xff) / 255.0
            b = Double(rgb & 0xff) / 255.0
        } else {
            // Fallback to white if parsing fails
            r = 1.0; g = 1.0; b = 1.0
        }
        
        self.init(red: r, green: g, blue: b)
    }
    
    /// Platform-specific color (UIColor on iOS, NSColor on macOS)
    var platformColor: PlatformColor {
        #if canImport(UIKit)
        return PlatformColor(self)
        #elseif canImport(AppKit)
        return PlatformColor(self)
        #endif
    }
    
    /// Convert SwiftUI Color to CGColor for SceneKit
    var cgColor: CGColor {
        platformColor.cgColor
    }
}

// MARK: - Notification extension for settings update

extension Notification.Name {
    static let starfieldSettingsUpdated = Notification.Name("starfieldSettingsUpdated")
    static let starfieldSelectedStarScreenPoint = Notification.Name("starfieldSelectedStarScreenPoint")
}

// MARK: - Star Node

/// Custom SCNNode subclass that stores associated star metadata.
class StarNode: SCNNode {
    let star: Star
    let originalSize: CGFloat
    
    init(star: Star, geometry: SCNGeometry, originalSize: CGFloat) {
        self.star = star
        self.originalSize = originalSize
        super.init()
        self.geometry = geometry
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Star Node Factory

/// Creates SceneKit nodes for individual stars.
class StarNodeFactory {
    
    /// Create a star node with a sphere geometry, material, and optional glow effect.
    static func createStarNode(for star: Star) -> SCNNode {
        let size = StarSizer.size(for: star.magnitude)
        
        // Main star sphere
        let sphere = SCNSphere(radius: size)
        sphere.segmentCount = 16
        
        let material = SCNMaterial()
    material.diffuse.contents = Color(hex: star.color).platformColor
        material.lightingModel = .constant  // Unlit (like MeshBasicMaterial in Three.js)
        material.isDoubleSided = false
        sphere.materials = [material]
        
        let starNode = StarNode(star: star, geometry: sphere, originalSize: size)
        starNode.position = CoordinateConverter.raDecToVector3(
            ra: star.rightAscension,
            dec: star.declination,
            distance: star.distance
        )
        
        // Store star metadata for selection
        starNode.name = star.name
        
        // Add glow effect (slightly larger, semi-transparent sphere)
        let glowSphere = SCNSphere(radius: size * 1.5)
        let glowMaterial = SCNMaterial()
    glowMaterial.diffuse.contents = Color(hex: star.color).opacity(0.3).platformColor
        glowMaterial.lightingModel = .constant
        glowMaterial.isDoubleSided = true
        glowSphere.materials = [glowMaterial]
        
        let glowNode = SCNNode(geometry: glowSphere)
        glowNode.opacity = 0.3
        starNode.addChildNode(glowNode)
        
        return starNode
    }
}

// MARK: - Background Stars (Particle System)

/// Creates a background starfield using SceneKit particle system for ambiance.
class BackgroundStarFactory {
    
    static func createBackgroundStars() -> SCNNode {
        let particleSystem = SCNParticleSystem()
        
        // Configure particle system to emit many static points
        particleSystem.birthRate = 5000
        particleSystem.particleLifeSpan = 1000  // effectively infinite
        particleSystem.emissionDuration = 0.1   // emit once at start
        particleSystem.loops = false
        particleSystem.particleSize = 1.0
    particleSystem.particleColor = Color.white.opacity(0.6).platformColor
        
        // Emit from a large sphere
        let emitterShape = SCNSphere(radius: 2000)
        particleSystem.emitterShape = emitterShape
        particleSystem.birthLocation = .surface
        particleSystem.birthDirection = .random
        
        // Slight color variation (white to light blue)
        particleSystem.particleColorVariation = SCNVector4(0.1, 0.1, 0.2, 0.0)
        
        let particleNode = SCNNode()
        particleNode.addParticleSystem(particleSystem)
        
        return particleNode
    }
}

// MARK: - Scene Manager

/// Manages the SceneKit scene: creates camera, lights, stars, and handles configuration.
class StarfieldSceneManager {
    
    let scene = SCNScene()
    private(set) var cameraNode: SCNNode!
    private(set) var starNodes: [SCNNode] = []
    private var backgroundNode: SCNNode?
    
    init() {
        setupScene()
        setupCamera()
        setupLights()
    }
    
    private func setupScene() {
    scene.background.contents = PlatformColor.black
        // Fog for depth (exponential fog to mimic Three.js)
    scene.fogColor = PlatformColor.black
        scene.fogDensityExponent = 0.00025
    }
    
    private func setupCamera() {
        cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 10000
        cameraNode.position = SCNVector3(0, 0, 500)
        scene.rootNode.addChildNode(cameraNode)
    }
    
    private func setupLights() {
        // Ambient light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
    let ambientBase = Color.gray.opacity(0.25)
    #if canImport(UIKit)
    ambientLight.color = ambientBase.platformColor
    #elseif canImport(AppKit)
    ambientLight.color = ambientBase.platformColor
    #endif
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)
        
        // Point light at origin (subtle)
        let pointLight = SCNLight()
        pointLight.type = .omni
    pointLight.color = PlatformColor.white
        pointLight.intensity = 1000
        let pointNode = SCNNode()
        pointNode.light = pointLight
        pointNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(pointNode)
    }
    
    /// Load stars and add them to the scene.
    func loadStars(_ stars: [Star]) {
        // Remove existing star nodes
    starNodes.forEach { $0.removeFromParentNode() }
        starNodes.removeAll()
        
        // Create and add star nodes
        for star in stars {
            let node = StarNodeFactory.createStarNode(for: star)
            scene.rootNode.addChildNode(node)
            starNodes.append(node)
        }
        
        // Add background starfield (managed via settings)
        if backgroundNode == nil {
            backgroundNode = BackgroundStarFactory.createBackgroundStars()
            if let backgroundNode {
                scene.rootNode.addChildNode(backgroundNode)
            }
        }
    }
    
    func apply(settings: StarfieldViewModel.Settings) {
        // Background stars visibility
        backgroundNode?.isHidden = !settings.showBackgroundStars
        // Fog density
        scene.fogDensityExponent = settings.fogDensityExponent
        // Camera controls are applied on SCNView; stored for later via notification
        NotificationCenter.default.post(name: .starfieldSettingsUpdated, object: nil, userInfo: [
            "cameraAllowsControl": settings.cameraAllowsControl,
            "starSizeScale": settings.starSizeScale
        ])
        // Scale all star nodes
        for node in starNodes {
            if let starNode = node as? StarNode {
                let scale = Float(settings.starSizeScale)
                starNode.scale = SCNVector3(x: scale, y: scale, z: scale)
                // Also scale the glow child, if present (first child is glow sphere)
                if let glow = starNode.childNodes.first {
                    glow.scale = SCNVector3(x: scale, y: scale, z: scale)
                }
            }
        }
    }
}

// MARK: - SwiftUI View

/// SwiftUI wrapper for the SceneKit starfield view.
/// Use this in your SwiftUI app by adding `StarfieldView()` to your view hierarchy.
@available(iOS 15.0, *)
struct StarfieldView: View {
    @StateObject private var viewModel = StarfieldViewModel()
    @State private var showSettings = false
    
    var body: some View {
        ZStack {
            // SceneKit view
            SceneKitViewRepresentable(sceneManager: viewModel.sceneManager,
                                      selectedStar: $viewModel.selectedStar,
                                      settings: $viewModel.settings)
                .edgesIgnoringSafeArea(.all)
            
            // Star info overlay
            if let star = viewModel.selectedStar, let pos = viewModel.infoPanelPosition {
                GeometryReader { proxy in
                    let size = proxy.size
                    let padding: CGFloat = 12
                    let panelWidth: CGFloat = 300
                    let panelHeight: CGFloat = 200
                    let offsetX: CGFloat = 16

                    let desiredX = pos.x + offsetX + panelWidth / 2
                    let desiredY = pos.y

                    let clampedX = min(max(desiredX, padding + panelWidth / 2), size.width - padding - panelWidth / 2)
                    let clampedY = min(max(desiredY, padding + panelHeight / 2), size.height - padding - panelHeight / 2)

                    StarInfoPanel(star: star, opacity: viewModel.settings.infoPanelOpacity, onClose: {
                        viewModel.selectedStar = nil
                        viewModel.infoPanelPosition = nil
                    })
                    .fixedSize()
                    .position(x: clampedX, y: clampedY)
                    .transition(.opacity)
                    .zIndex(3)
                }
            }
            
            // Settings button
            VStack {
                HStack {
                    Spacer()
                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                    }
                    .padding([.top, .trailing])
                }
                Spacer()
            }
            
            if showSettings {
                SettingsPanel(
                    isPresented: $showSettings,
                    settings: $viewModel.settings
                )
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }
            
            // Loading indicator
            if viewModel.isLoading {
                ProgressView("Loading stars...")
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(10)
            }
            
            // Error message
            if let error = viewModel.errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(10)
                        .padding()
                }
            }
        }
        .onAppear {
            viewModel.loadStars()
            viewModel.applySettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .starfieldSelectedStarScreenPoint)) { note in
            if let point = note.userInfo?["point"] as? CGPoint {
                // SCNView's coordinate system origin is top-left for UIKit, but projectPoint returns in view space; convert if needed
                viewModel.infoPanelPosition = point
            }
        }
    }
}

// MARK: - SwiftUI ViewModel

@available(iOS 15.0, *)
class StarfieldViewModel: ObservableObject {
    @Published var selectedStar: Star?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var infoPanelPosition: CGPoint? = nil
    
    struct Settings: Equatable {
        var showBackgroundStars: Bool = true
        var fogDensityExponent: CGFloat = 0.00025
        var cameraAllowsControl: Bool = true
        var starSizeScale: CGFloat = 1.0
        var infoPanelOpacity: CGFloat = 0.85
    }

    @Published var settings = Settings()
    
    let sceneManager = StarfieldSceneManager()
    
    func loadStars() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let stars = try await StarLoader.loadFromBundle(filename: "data.json")
                await MainActor.run {
                    sceneManager.loadStars(stars)
                    isLoading = false
                    print("Loaded \(stars.count) stars")
                    applySettings()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Error loading stars: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func applySettings() {
        sceneManager.apply(settings: settings)
    }
}

// MARK: - SwiftUI SceneKit Representable

@available(iOS 15.0, *)
struct SceneKitViewRepresentable: UIViewRepresentable {
    let sceneManager: StarfieldSceneManager
    @Binding var selectedStar: Star?
    @Binding var settings: StarfieldViewModel.Settings
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.scene = sceneManager.scene
        sceneView.allowsCameraControl = settings.cameraAllowsControl
        #if canImport(UIKit)
        sceneView.backgroundColor = .black
        #elseif canImport(AppKit)
        sceneView.backgroundColor = .black
        #endif
        sceneView.antialiasingMode = .multisampling4X
        
        // Add tap gesture
        #if canImport(UIKit)
        let tapGesture = UITapGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleTap(_:)))
        sceneView.addGestureRecognizer(tapGesture)
        #elseif canImport(AppKit)
        let tapGesture = NSClickGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleTap(_:)))
        sceneView.addGestureRecognizer(tapGesture)
        #endif
        
        context.coordinator.sceneView = sceneView
        context.coordinator.setupObservers(for: sceneView)
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        sceneManager.apply(settings: settings)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(sceneManager: sceneManager, selectedStar: $selectedStar)
    }
    
    class Coordinator: NSObject {
        let sceneManager: StarfieldSceneManager
        @Binding var selectedStar: Star?
        weak var sceneView: SCNView?
        private var settingsObserver: NSObjectProtocol?
        
        init(sceneManager: StarfieldSceneManager, selectedStar: Binding<Star?>) {
            self.sceneManager = sceneManager
            self._selectedStar = selectedStar
        }
        
        deinit {
            if let observer = settingsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        func setupObservers(for sceneView: SCNView) {
            // Remove any existing observer first
            if let observer = settingsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            
            // Add observer and store the token for cleanup
            settingsObserver = NotificationCenter.default.addObserver(
                forName: .starfieldSettingsUpdated,
                object: nil,
                queue: .main
            ) { [weak sceneView] note in
                if let allows = note.userInfo?["cameraAllowsControl"] as? Bool {
                    sceneView?.allowsCameraControl = allows
                }
            }
        }
        
        @objc func handleTap(_ gesture: Any) {
            guard let sceneView = sceneView else { return }
            
            #if canImport(UIKit)
            guard let tapGesture = gesture as? UITapGestureRecognizer else { return }
            let location = tapGesture.location(in: sceneView)
            #elseif canImport(AppKit)
            guard let clickGesture = gesture as? NSClickGestureRecognizer else { return }
            let location = clickGesture.location(in: sceneView)
            #else
            return
            #endif
            
            let hitResults = sceneView.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue
            ])
            
            if let hit = hitResults.first {
                let targetNode: StarNode? = {
                    if let starNode = hit.node as? StarNode {
                        return starNode
                    } else if let parent = hit.node.parent as? StarNode {
                        return parent
                    } else {
                        return nil
                    }
                }()
                
                if let starNode = targetNode {
                    let projected = sceneView.projectPoint(starNode.worldPosition)
                    let projectedPointInView = CGPoint(
                        x: CGFloat(projected.x),
                        y: sceneView.bounds.height - CGFloat(projected.y)
                    )
                    NotificationCenter.default.post(
                        name: .starfieldSelectedStarScreenPoint,
                        object: nil,
                        userInfo: ["point": projectedPointInView]
                    )
                    selectedStar = starNode.star
                    highlightNode(starNode)
                    return
                }
            }
            
            selectedStar = nil
        }
        
        private func highlightNode(_ node: SCNNode) {
            let scaleAction = SCNAction.scale(to: 1.5, duration: 0.2)
            node.runAction(scaleAction)
        }
    }
}

// MARK: - SwiftUI Star Info Panel

@available(iOS 15.0, *)
struct StarInfoPanel: View {
    let star: Star
    let opacity: CGFloat
    let onClose: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(star.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            Divider().background(Color.white.opacity(0.3))
            
            InfoRow(label: "Type", value: star.type)
            InfoRow(label: "Magnitude", value: String(format: "%.2f", star.magnitude))
            InfoRow(label: "Distance", value: "\(String(format: "%.1f", star.distance)) ly")
            InfoRow(label: "Temperature", value: "\(star.temperature.formatted()) K")
        }
        .padding()
        .background(Color.black.opacity(opacity))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
}

@available(iOS 15.0, *)
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.white.opacity(0.7))
            Text(value)
                .foregroundColor(.white)
        }
        .font(.subheadline)
    }
}

// MARK: - Settings Panel

@available(iOS 15.0, *)
struct SettingsPanel: View {
    @Binding var isPresented: Bool
    @Binding var settings: StarfieldViewModel.Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.headline).foregroundColor(.white)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Toggle(isOn: $settings.showBackgroundStars) {
                Text("Show Background Stars").foregroundColor(.white)
            }

            Toggle(isOn: $settings.cameraAllowsControl) {
                Text("Allow Camera Control").foregroundColor(.white)
            }

            VStack(alignment: .leading) {
                Text("Fog Density").foregroundColor(.white)
                Slider(value: Binding(get: {
                    Double(settings.fogDensityExponent)
                }, set: { newVal in
                    settings.fogDensityExponent = CGFloat(newVal)
                }), in: 0...0.002)
            }

            VStack(alignment: .leading) {
                Text("Star Size Scale").foregroundColor(.white)
                Slider(value: $settings.starSizeScale, in: 0.5...2.0)
            }
            
            VStack(alignment: .leading) {
                Text("Info Panel Opacity").foregroundColor(.white)
                Slider(value: $settings.infoPanelOpacity, in: 0.3...1.0)
            }
        }
        .padding()
        .background(Color.black.opacity(0.9))
        .cornerRadius(12)
        .shadow(radius: 10)
        .frame(maxWidth: 320)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

