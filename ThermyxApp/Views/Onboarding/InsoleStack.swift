import GLTFKit2
import SceneKit
import SwiftUI

// The insole's hardware model (the website's hardware-model.glb), exploded
// into vertical stacks the way the website does it: every part lifts
// straight up by its own offset × the explode amount. The explode button
// drives it, a horizontal drag turns it (within limits), and a tap picks a
// part to read about, outlined in a glow.

/// One part of the insole or power pack, as the website describes it.
struct InsolePart: Equatable {
    let match: String
    let product: String
    let label: String
    let role: String
    let detail: String?
    /// Lift at full explode, in millimetres along the model's up axis.
    let liftMM: Double

    /// The website's exploded-view offsets and component copy
    /// (Thermyx-site src/data/explode.js and components.js).
    static let all: [InsolePart] = [
        .init(match: "Comfort_Top_Layer", product: "Insole", label: "Comfort top layer",
              role: "The surface your foot rests on, laid over the three pressure sensors.", detail: "3 mm", liftMM: 95),
        .init(match: "Pressure_Sensor_-_Heel", product: "Insole", label: "Heel pressure sensor",
              role: "A force-sensing resistor under the heel. With the arch and forefoot sensors, it tracks how your weight moves through each step.", detail: "FSR 402", liftMM: 70),
        .init(match: "Pressure_Sensor_-_Arch", product: "Insole", label: "Arch pressure sensor",
              role: "A force-sensing resistor under the arch, one of the three zones the insole reads load from.", detail: "FSR 402", liftMM: 70),
        .init(match: "Pressure_Sensor_-_Forefoot", product: "Insole", label: "Forefoot pressure sensor",
              role: "A force-sensing resistor under the forefoot. Its share of the load is the pressure balance the app reports.", detail: "FSR 402", liftMM: 70),
        .init(match: "Peltier_Module", product: "Insole", label: "Peltier module",
              role: "A solid-state heat pump under the heel. Driven one way it cools the foot; reversed, it warms it. The firmware never heats at or above 40 °C.", detail: "Dilwe TEC1-04901 · 25 × 25 × 4 mm", liftMM: 30),
        .init(match: "Temperature_Sensor_-_Foot_Contact", product: "Insole", label: "Foot temperature sensor",
              role: "Reads temperature where your foot meets the insole. Every heating and cooling decision, and the burn cutoff, runs off this reading.", detail: nil, liftMM: 45),
        .init(match: "Temperature_Sensor_-_Peltier_Hot_Side", product: "Insole", label: "Second temperature sensor",
              role: "A second temperature sensor, mounted beside the Peltier module.", detail: nil, liftMM: 45),
        .init(match: "MCU_", product: "Insole", label: "Microcontroller",
              role: "The insole's brain. It reads every sensor once a second, streams them to the app over Bluetooth, and enforces the safety limits whatever the app sends.", detail: "Seeed XIAO ESP32-C3", liftMM: 38),
        .init(match: "IMU_", product: "Insole", label: "Motion sensor",
              role: "Detects steps from acceleration, giving the app your cadence, time spent standing, and how steady your gait is.", detail: "GY-521 · MPU-6050", liftMM: 38),
        .init(match: "Peltier_Driver_", product: "Insole", label: "Peltier driver",
              role: "A dual H-bridge. One channel runs the Peltier in either direction to heat or cool; the other runs the cooling fan.", detail: "NOYITO DRV8833", liftMM: 38),
        .init(match: "Fuse_Holder_", product: "Insole", label: "Inline fuse",
              role: "Cuts the circuit if current runs too high, protecting the wiring and electronics.", detail: "BOJACK 5 × 20 mm · 2 A", liftMM: 35),
        .init(match: "Enclosure_Lid", product: "Insole", label: "Electronics enclosure",
              role: "Houses the microcontroller, motion sensor, and Peltier driver inside the insole.", detail: "68 × 28 mm", liftMM: 55),
        .init(match: "Enclosure_Base", product: "Insole", label: "Electronics enclosure",
              role: "Houses the microcontroller, motion sensor, and Peltier driver inside the insole.", detail: "68 × 28 mm", liftMM: 20),
        .init(match: "Insole_Base", product: "Insole", label: "Insole base",
              role: "The main structure of the insole. Every sensor and module is carried inside it.", detail: "301 × 107 × 27 mm", liftMM: 0),
        .init(match: "Outsole_Layer", product: "Insole", label: "Outsole layer",
              role: "The bottom wear layer, where the insole meets the shoe.", detail: "1.9 mm", liftMM: -30),
        .init(match: "Battery_Bay_Lid", product: "Power pack", label: "Battery bay lid",
              role: "The removable cover over the battery bay.", detail: nil, liftMM: 70),
        .init(match: "Battery_", product: "Power pack", label: "Battery",
              role: "The power bank that runs the insole, the Peltier, and the fan, in its own removable bay.", detail: "INIU P55 · 10,000 mAh", liftMM: 30),
        .init(match: "Heat_Sink_", product: "Power pack", label: "Heat sink",
              role: "Aluminum fins that shed the heat the Peltier pulls away from the foot.", detail: "Awxlumv · 25 × 25 × 10 mm", liftMM: 30),
        .init(match: "Cooling_Fan_", product: "Power pack", label: "Cooling fan",
              role: "Pushes air across the heat sink whenever the insole is cooling.", detail: "Easycargo · 20 × 20 × 6 mm · 5 V", liftMM: 50),
        .init(match: "External_Compartment_Shell", product: "Power pack", label: "Power pack shell",
              role: "Holds the battery, heat sink, and fan outside the insole.", detail: "150 × 70 × 20 mm", liftMM: 0),
    ]

    /// Longest prefix first, matched against the glTF node name with spaces
    /// as underscores (as the website's loader names them).
    static func find(_ nodeName: String) -> InsolePart? {
        let name = nodeName.replacingOccurrences(of: " ", with: "_")
        return all.sorted { $0.match.count > $1.match.count }.first { name.hasPrefix($0.match) }
    }
}

struct InsoleStack: UIViewRepresentable {
    /// Taken apart or assembled. The model springs between the two.
    var exploded: Bool
    @Binding var selected: InsolePart?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        context.coordinator.attach(to: view, reduceMotion: reduceMotion)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.target = exploded ? 1 : 0
        if selected == nil { context.coordinator.clearSelection() }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private struct Part {
            let node: SCNNode
            let home: SCNVector3
            let lift: SCNVector3
            let info: InsolePart
            let outlines: [SCNNode]
            let materials: [SCNMaterial]
        }

        var parent: InsoleStack
        var target = 0.0
        private weak var view: SCNView?
        private weak var turntable: SCNNode?
        private weak var camera: SCNNode?
        private var parts: [Part] = []
        private var value = 0.0, velocity = 0.0
        private var yaw = 0.0, yawTarget = 0.0, yawStart = 0.0
        private var link: CADisplayLink?
        private var reduceMotion = false
        /// Camera framing for the assembled and exploded model: distance
        /// and the height it looks at.
        private var framing: (near: (Float, Float), far: (Float, Float)) = ((1, 0), (1, 0))

        /// How fast the model follows the finger.
        private let yawPerPoint = 0.006

        init(_ parent: InsoleStack) { self.parent = parent }

        func attach(to view: SCNView, reduceMotion: Bool) {
            self.view = view
            self.reduceMotion = reduceMotion
            view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
            guard let url = Bundle.main.url(forResource: "insole", withExtension: "glb") else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let scene = (try? GLTFAsset(url: url, options: [:])).flatMap { GLTFSCNSceneSource(asset: $0).defaultScene }
                DispatchQueue.main.async { [weak self] in if let scene { self?.present(scene) } }
            }
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func detach() {
            link?.invalidate()
            link = nil
        }

        // MARK: Scene

        private func present(_ scene: SCNScene) {
            guard let view else { return }
            scene.background.contents = UIColor.clear
            // turntable (tilts left and right) → mirror → faceZ → faceX → model.
            let turntable = SCNNode()
            let mirror = SCNNode()
            let faceZ = SCNNode(), faceX = SCNNode()
            let model = SCNNode()
            for child in scene.rootNode.childNodes { model.addChildNode(child) }
            faceX.addChildNode(model)
            faceZ.addChildNode(faceX)
            mirror.addChildNode(faceZ)
            turntable.addChildNode(mirror)
            scene.rootNode.addChildNode(turntable)
            self.turntable = turntable

            model.enumerateChildNodes { node, _ in
                guard let name = node.name, let info = InsolePart.find(name), node.parent?.name?.hasPrefix("Fusion") == true else { return }
                self.parts.append(Part(node: node, home: node.position, lift: SCNVector3(0, 0, Float(info.liftMM / 1000)),
                                       info: info, outlines: [], materials: []))
            }

            // Face the wearer: the model's up (+Y, where the parts lift)
            // turns toward the camera, and the insole's length runs up the
            // screen.
            apply(0)
            let rest = model.boundingBox
            let lengthAlongX = (rest.max.x - rest.min.x) >= (rest.max.z - rest.min.z)
            faceX.eulerAngles.x = .pi / 2
            faceZ.eulerAngles.z = lengthAlongX ? .pi / 2 : 0
            // Reflected across the screen's vertical axis and turned 180°.
            mirror.scale = SCNVector3(-1, 1, 1)
            mirror.eulerAngles.z = .pi

            // Centre it, then fit the length to the height of the view and
            // the width to its width, leaving room for the stack to come
            // toward the camera when it's taken apart.
            let faced = turntable.boundingBox
            // Centred in the turntable's space, so the offset goes on the
            // mirror, whose translation isn't reflected.
            mirror.position = SCNVector3(-(faced.min.x + faced.max.x) / 2, -(faced.min.y + faced.max.y) / 2, -(faced.min.z + faced.max.z) / 2)
            apply(1)
            let open = turntable.boundingBox
            apply(0)
            let fov: Float = 28
            let aspect = view.bounds.height > 0 ? Float(view.bounds.width / view.bounds.height) : 0.8
            let halfTan = tan(fov / 2 * .pi / 180)
            // It spins all the way round, so fit the widest it gets from any
            // side: the diagonal across its width and depth, taken apart.
            let wide = sqrt(pow(open.max.x - open.min.x, 2) + pow(open.max.z - open.min.z, 2))
            let fit = max((open.max.y - open.min.y) / 2 / halfTan, wide / 2 / (halfTan * aspect))
            let distance = fit * 1.04 + wide / 2
            framing = ((distance, 0), (distance, 0))

            // Outlines after measuring, so they never count toward the frame.
            parts = parts.map { p in
                Part(node: p.node, home: p.home, lift: p.lift, info: p.info,
                     outlines: Self.outlines(for: p.node, color: Self.accent(p.info)), materials: p.materials)
            }

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = CGFloat(fov)
            camera.camera?.projectionDirection = .vertical
            camera.camera?.zNear = 0.001
            camera.camera?.zFar = 100
            camera.camera?.wantsHDR = true
            camera.camera?.wantsExposureAdaptation = false
            // Only light brighter than white blooms: the glow outlines and
            // the ember sensors, never the glass.
            camera.camera?.bloomIntensity = 1.4
            camera.camera?.bloomThreshold = 1.0
            camera.camera?.bloomBlurRadius = 9
            camera.camera?.exposureOffset = -0.4
            scene.rootNode.addChildNode(camera)
            self.camera = camera
            placeCamera()
            Self.light(scene)
            view.pointOfView = camera
            view.scene = scene
            // Restyle once the scene is attached: SceneKit keeps the
            // materials a geometry had when it first saw it.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0
                self.parts = self.parts.map { p in
                    Part(node: p.node, home: p.home, lift: p.lift, info: p.info, outlines: p.outlines,
                         materials: Self.restyle(p.node, info: p.info))
                }
                SCNTransaction.commit()
            }
            #if DEBUG
            // `-ThermyxExplode`: opens taken apart, for review.
            if ProcessInfo.processInfo.arguments.contains("-ThermyxExplode") { value = 1; target = 1; apply(1) }
            // `-ThermyxSelect <prefix>`: opens with a part picked.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-ThermyxSelect"), i + 1 < args.count, let part = parts.first(where: { $0.info.match.hasPrefix(args[i + 1]) }) {
                select(part)
                parent.selected = part.info
            }
            #endif
        }

        /// Straight on, looking at the insole's top face.
        private func placeCamera() {
            guard let camera else { return }
            camera.position = SCNVector3(0, 0, framing.near.0)
            camera.look(at: SCNVector3Zero)
        }

        private func apply(_ amount: Double) {
            let a = Float(max(-0.08, amount))
            for p in parts {
                p.node.position = SCNVector3(p.home.x + p.lift.x * a, p.home.y + p.lift.y * a, p.home.z + p.lift.z * a)
            }
        }

        // MARK: Look
        //
        // The website's materials, in SceneKit terms: the comfort layer is
        // tinted glass, the insole body a clear-coated translucent grey,
        // the enclosures and pack shell a dark satin plastic, and parts on
        // the heat path glow ember while the rest of the electronics keep
        // their CAD colours.

        private static let outlineName = "thermyx.outline"
        private static let glass = ["Comfort_Top_Layer"]
        private static let translucent = ["Insole_Base", "Outsole_Layer"]
        private static let shells = ["Enclosure_Base", "Enclosure_Lid", "External_Compartment_Shell", "Battery_Bay_Lid"]
        private static let heatPath = ["Temperature_Sensor_-_Peltier_Hot_Side", "Heat_Sink_", "Cooling_Fan_"]

        static func accent(_ info: InsolePart) -> UIColor {
            heatPath.contains { info.match.hasPrefix($0) } ? UIColor(Thermyx.Ink.ember) : UIColor(Thermyx.Ink.ice)
        }

        /// A faint ice-blue rim where surfaces turn away from the camera, so
        /// the model glows softly at its edges; the brightest edges catch a
        /// little bloom. abs() because the mirror flips the normals.
        private static let rimGlow = """
        float facing = abs(dot(normalize(_surface.normal), normalize(_surface.view)));
        float rim = pow(1.0 - facing, 3.0);
        _output.color.rgb += float3(0.36, 0.82, 1.0) * rim * 0.9 * _output.color.a;
        """

        private static func restyle(_ node: SCNNode, info: InsolePart) -> [SCNMaterial] {
            var geometries: [SCNGeometry] = []
            node.enumerateHierarchy { child, _ in
                guard let g = child.geometry, child.name != Self.outlineName else { return }
                // A fresh geometry over the same vertex data, carrying none
                // of the loader's state.
                let fresh = SCNGeometry(sources: g.sources, elements: g.elements)
                fresh.materials = g.materials
                child.geometry = fresh
                geometries.append(fresh)
            }
            // Fresh materials: the loader's own shaders for the glTF glass
            // extensions would override anything set on its materials.
            for geometry in geometries {
                geometry.shaderModifiers = nil
                geometry.program = nil
                geometry.materials = geometry.materials.map { old in
                    let m = SCNMaterial()
                    m.diffuse.contents = old.diffuse.contents
                    m.name = old.name
                    return m
                }
            }
            let materials = geometries.flatMap(\.materials)
            for m in materials {
                // The model is shown mirrored, which turns its faces inside
                // out: cull the other side.
                m.cullMode = .front
                m.lightingModel = .physicallyBased
                m.shaderModifiers = [.fragment: rimGlow]
                if glass.contains(info.match) {
                    // Smoked glass, as on the website over black.
                    m.diffuse.contents = UIColor(red: 0.30, green: 0.36, blue: 0.50, alpha: 1)
                    m.metalness.contents = 0.0
                    m.roughness.contents = 0.12
                    m.transparency = 0.38
                } else if translucent.contains(info.match) {
                    // The x-rayed body: a dark, see-through grey.
                    m.diffuse.contents = UIColor(red: 0.26, green: 0.28, blue: 0.31, alpha: 1)
                    m.metalness.contents = 0.0
                    m.roughness.contents = 0.3
                    m.transparency = info.match == "Insole_Base" ? 0.42 : 0.55
                } else if shells.contains(where: { info.match.hasPrefix($0) }) {
                    m.diffuse.contents = UIColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1)
                    m.metalness.contents = 0.0
                    m.roughness.contents = 0.55
                } else if info.match.hasPrefix("Pressure_Sensor") {
                    m.diffuse.contents = UIColor(Thermyx.Ink.ember)
                    m.emission.contents = UIColor(Thermyx.Ink.ember).withAlphaComponent(1)
                    m.emission.intensity = 1.6
                    m.roughness.contents = 0.4
                } else {
                    m.roughness.contents = 0.45
                    m.metalness.contents = info.match.hasPrefix("Heat_Sink") ? 0.9 : 0.1
                }
            }
            // Glass and translucent parts draw after the solid ones.
            let order = glass.contains(info.match) ? 20 : (translucent.contains(info.match) ? 10 : 0)
            node.enumerateHierarchy { child, _ in if child.name != Self.outlineName { child.renderingOrder = order } }
            return materials
        }

        /// A slightly larger, inside-out copy of each of the part's meshes in
        /// flat accent colour, in the mesh's own space: its rim shows as a
        /// glowing outline, and bloom softens it.
        private static func outlines(for node: SCNNode, color: UIColor) -> [SCNNode] {
            var hulls: [SCNNode] = []
            var sources: [SCNNode] = []
            node.enumerateHierarchy { child, _ in if child.geometry != nil, child.name != outlineName { sources.append(child) } }
            for source in sources {
                guard let geometry = source.geometry?.copy() as? SCNGeometry else { continue }
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = color
                material.emission.contents = color
                material.emission.intensity = 2.5
                // Inside-out hull, under the mirror.
                material.cullMode = .back
                material.writesToDepthBuffer = false
                geometry.materials = [material]
                let hull = SCNNode(geometry: geometry)
                hull.name = outlineName
                let (lo, hi) = geometry.boundingBox
                let c = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
                // Grow about the part's own centre by a fixed margin, so thin
                // parts get as visible a rim as large ones.
                let size = SCNVector3(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
                let margin: Float = 0.0025
                hull.pivot = SCNMatrix4MakeTranslation(c.x, c.y, c.z)
                hull.position = c
                hull.scale = SCNVector3(1 + 2 * margin / max(size.x, 0.002), 1 + 2 * margin / max(size.y, 0.002), 1 + 2 * margin / max(size.z, 0.002))
                hull.renderingOrder = 30
                hull.opacity = 0
                source.addChildNode(hull)
                hulls.append(hull)
            }
            return hulls
        }

        private static func light(_ scene: SCNScene) {
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 220
            ambient.light?.color = UIColor(white: 0.9, alpha: 1)
            scene.rootNode.addChildNode(ambient)
            for (direction, intensity, tint) in [
                (SCNVector3(-0.6, -1, -0.5), 700.0, UIColor.white),                      // key, above front
                (SCNVector3(0.8, -0.3, 0.6), 260.0, UIColor(red: 0.8, green: 0.9, blue: 1, alpha: 1)), // cool fill
                (SCNVector3(0, -0.2, 1), 380.0, UIColor(red: 1, green: 0.75, blue: 0.6, alpha: 1)),    // warm rim, behind
            ] {
                let node = SCNNode()
                node.light = SCNLight()
                node.light?.type = .directional
                node.light?.intensity = CGFloat(intensity)
                node.light?.color = tint
                node.look(at: direction)
                scene.rootNode.addChildNode(node)
            }
        }

        // MARK: Motion

        @objc private func frame(_ link: CADisplayLink) {
            let dt = min(link.targetTimestamp - link.timestamp, 1.0 / 30)
            if value != target || velocity != 0 {
                if reduceMotion {
                    value = target; velocity = 0
                } else {
                    // The website's explode spring.
                    let stiffness = 170.0, damping = 20.0
                    velocity += (stiffness * (target - value) - damping * velocity) * dt
                    value += velocity * dt
                    if abs(target - value) < 1e-4, abs(velocity) < 1e-3 { value = target; velocity = 0 }
                }
                apply(value)
            }
            if yaw != yawTarget {
                yaw += (yawTarget - yaw) * (reduceMotion ? 1 : min(1, dt * 14))
                if abs(yawTarget - yaw) < 1e-4 { yaw = yawTarget }
            }
            // Taken apart, it turns a little on its own so the layers read
            // as a stack; the wearer's tilt adds to that, within the limit.
            let shown = yaw + explodeTurn * min(max(value, 0), 1)
            if let turntable, turntable.eulerAngles.y != Float(shown) { turntable.eulerAngles.y = Float(shown) }
        }

        /// How far the model turns by itself when taken apart, in radians.
        private let explodeTurn = 0.55

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            let dx = Double(gesture.translation(in: gesture.view).x)
            switch gesture.state {
            case .began:
                yawStart = yawTarget
            case .changed:
                // Side to side, all the way round.
                yawTarget = yawStart + dx * yawPerPoint
            default:
                break
            }
        }

        // MARK: Inspect

        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            // The nearest part that isn't an outline.
            let chosen = hits.lazy.compactMap { hit -> Part? in
                var node: SCNNode? = hit.node
                while let current = node, !self.parts.contains(where: { $0.node === current }) {
                    if self.parts.contains(where: { $0.outlines.contains { $0 === current } }) { return nil }
                    node = current.parent
                }
                return self.parts.first { $0.node === node }
            }.first
            guard let chosen else {
                clearSelection()
                parent.selected = nil
                return
            }
            select(chosen)
            parent.selected = chosen.info
            UISelectionFeedbackGenerator().selectionChanged()
        }

        private func select(_ chosen: Part) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = reduceMotion ? 0 : 0.25
            for p in parts {
                let on = p.node === chosen.node
                // Matching parts (both enclosure halves) light together.
                let sameLabel = p.info.label == chosen.info.label
                p.node.opacity = on || sameLabel ? 1 : 0.22
                for o in p.outlines { o.opacity = on || sameLabel ? 1 : 0 }
                for m in p.materials where !p.info.match.hasPrefix("Pressure_Sensor") {
                    m.emission.contents = on || sameLabel ? Self.accent(p.info) : UIColor.black
                    m.emission.intensity = on || sameLabel ? 0.35 : 0
                }
            }
            SCNTransaction.commit()
        }

        func clearSelection() {
            guard parts.contains(where: { $0.node.opacity < 1 || $0.outlines.contains { $0.opacity > 0 } }) else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = reduceMotion ? 0 : 0.25
            for p in parts {
                p.node.opacity = 1
                for o in p.outlines { o.opacity = 0 }
                for m in p.materials where !p.info.match.hasPrefix("Pressure_Sensor") {
                    m.emission.contents = UIColor.black
                    m.emission.intensity = 0
                }
            }
            SCNTransaction.commit()
        }
    }
}
