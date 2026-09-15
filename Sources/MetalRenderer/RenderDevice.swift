//
//  RenderDevice.swift
//  MetalRenderer
//

import Foundation
import Metal
import MetalFX
import os

// MARK: - Capabilities

/// An immutable snapshot of everything the renderer wants to know about the GPU.
///
/// Probed exactly once, at `RenderDevice` init. Capability queries like
/// `supportsFamily(_:)` are not free — they cross into the Metal driver — and the
/// answers cannot change for the lifetime of a device, so caching them keeps
/// per-frame and per-import code from ever having to ask again.
///
/// Thread-safe: immutable value type, `Sendable`, readable from any isolation domain.
public struct DeviceCapabilities: Sendable, Hashable {

    public let deviceName: String
    public let registryID: UInt64

    /// Apple Silicon shares one memory pool between CPU and GPU. When true, staging
    /// uploads can use `.storageModeShared` buffers with no extra copy step.
    public let hasUnifiedMemory: Bool

    /// True on all Apple Silicon: BC1/BC3/BC5/BC7 blocks are decoded in hardware.
    ///
    /// This is load-bearing. Wallpaper Engine's `.tex` files ship DXT-compressed, and
    /// if this is true we hand the compressed blocks straight to Metal. Transcoding to
    /// RGBA8 would cost 4-8x the VRAM and a multi-second CPU stall per wallpaper.
    public let supportsBCTextureCompression: Bool

    public let supportsAppleFamily7: Bool
    public let supportsAppleFamily8: Bool
    public let supportsAppleFamily9: Bool

    /// Soft ceiling on resident GPU memory before the system starts evicting.
    /// The FBO pool and texture cache derive their default budgets from this.
    public let recommendedMaxWorkingSetSize: UInt64

    public let maxBufferLength: Int

    /// Tier 2 argument buffers allow the material bindings to live in a single buffer
    /// instead of dozens of `setFragmentTexture` calls per draw.
    public let argumentBuffersTier: Int

    /// MetalFX spatial upscaling: render at 0.5-0.75x and upscale. On a 5K display
    /// this is the single largest GPU saving available to a background element.
    public let supportsMetalFXSpatialScaling: Bool

    /// Temporal upscaling needs motion vectors and depth, which a 2D compositor does
    /// not naturally produce. Probed for completeness; not currently used.
    public let supportsMetalFXTemporalScaling: Bool

    /// The highest Apple GPU family this device satisfies, as a small integer
    /// (`7`, `8`, `9`), or `0` if it satisfies none of them (Intel, or a simulator).
    public var appleFamilyLevel: Int {
        if supportsAppleFamily9 { return 9 }
        if supportsAppleFamily8 { return 8 }
        if supportsAppleFamily7 { return 7 }
        return 0
    }

    /// True when the device is Apple Silicon with hardware BC decode — the
    /// configuration the whole renderer is tuned for.
    public var isPreferredConfiguration: Bool {
        hasUnifiedMemory && supportsBCTextureCompression && appleFamilyLevel >= 7
    }

    init(probing device: any MTLDevice) {
        deviceName = device.name
        registryID = device.registryID
        hasUnifiedMemory = device.hasUnifiedMemory
        supportsBCTextureCompression = device.supportsBCTextureCompression
        supportsAppleFamily7 = device.supportsFamily(.apple7)
        supportsAppleFamily8 = device.supportsFamily(.apple8)
        supportsAppleFamily9 = device.supportsFamily(.apple9)
        recommendedMaxWorkingSetSize = device.recommendedMaxWorkingSetSize
        maxBufferLength = device.maxBufferLength
        argumentBuffersTier = device.argumentBuffersSupport == .tier2 ? 2 : 1
        supportsMetalFXSpatialScaling = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        supportsMetalFXTemporalScaling = MTLFXTemporalScalerDescriptor.supportsDevice(device)
    }
}

extension DeviceCapabilities: CustomStringConvertible {
    public var description: String {
        let workingSetMB = recommendedMaxWorkingSetSize / (1024 * 1024)
        return """
        \(deviceName) (registry 0x\(String(registryID, radix: 16)))
          apple family: \(appleFamilyLevel == 0 ? "none" : "apple\(appleFamilyLevel)")
          unified memory: \(hasUnifiedMemory)
          BC texture compression: \(supportsBCTextureCompression)
          argument buffers: tier \(argumentBuffersTier)
          recommended working set: \(workingSetMB) MB
          max buffer length: \(maxBufferLength / (1024 * 1024)) MB
          MetalFX: spatial=\(supportsMetalFXSpatialScaling) temporal=\(supportsMetalFXTemporalScaling)
        """
    }
}

// MARK: - Errors

public enum RenderDeviceError: Error, CustomStringConvertible {
    /// No Metal device at all. Possible on a headless CI runner with no GPU service.
    case noSystemDefaultDevice
    case commandQueueCreationFailed

    public var description: String {
        switch self {
        case .noSystemDefaultDevice:
            return "MTLCreateSystemDefaultDevice() returned nil; this machine has no usable Metal device."
        case .commandQueueCreationFailed:
            return "MTLDevice.makeCommandQueue() returned nil."
        }
    }
}

// MARK: - RenderDevice

/// Owns the `MTLDevice` and the renderer's command queue, plus the probed capability set.
///
/// ## Threading contract
///
/// `Sendable` and entirely `nonisolated`. `MTLDevice` and `MTLCommandQueue` are the two
/// Metal objects Apple documents as thread-safe, so this type may be constructed and read
/// from any isolation domain — including `MainActor` for a settings UI that wants to show
/// the GPU name, and from a test with no `RenderActor` in sight.
///
/// Everything *derived* from this device that holds mutable state (`FBOPool`,
/// `TextureCache`, `PipelineCache`, `RenderGraph`) is `@RenderActor`-isolated instead.
///
/// ## Construction
///
/// Use ``shared`` in the app. Use ``init(device:label:)`` in tests to inject a specific
/// or mock device. There is no enforced singleton: two `RenderDevice`s wrapping the same
/// `MTLDevice` are legal, they just each get their own command queue.
///
/// ## Headless
///
/// Nothing here requires a display, a `CAMetalLayer`, or a window server connection.
/// ``shared`` returns `nil` rather than trapping when no device exists, so CI can import
/// this module and exercise the pure-logic paths on a machine with no GPU.
public final class RenderDevice: Sendable {

    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let capabilities: DeviceCapabilities

    /// Logger shared by the whole module. `os.Logger` is used rather than `print`
    /// because it is lock-free at the call site and compiles out at disabled levels —
    /// a `print` on the render queue is a syscall per frame.
    public static let log = Logger(subsystem: "com.diorama.metalrenderer", category: "render")

    /// The process-wide device, created on first access.
    ///
    /// `nil` when the machine has no Metal device (headless CI). Callers that genuinely
    /// cannot proceed should surface that as a user-facing error, not a crash.
    ///
    /// Deliberately not a hard singleton: this is a convenience for the app's single
    /// render loop. Tests inject their own via ``init(device:label:)``.
    public static let shared: RenderDevice? = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("No system default Metal device; renderer unavailable.")
            return nil
        }
        return try? RenderDevice(device: device, label: "com.diorama.render")
    }()

    /// Wrap a caller-supplied device. Logs the capability set once, on construction.
    ///
    /// - Parameters:
    ///   - device: the Metal device to use.
    ///   - label: label applied to the created command queue, for GPU capture traces.
    public init(device: any MTLDevice, label: String = "com.diorama.render") throws {
        guard let queue = device.makeCommandQueue() else {
            throw RenderDeviceError.commandQueueCreationFailed
        }
        queue.label = label
        self.device = device
        self.commandQueue = queue
        self.capabilities = DeviceCapabilities(probing: device)
        logCapabilities()
    }

    /// Convenience for the common case, throwing instead of returning `nil`.
    public static func system() throws -> RenderDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderDeviceError.noSystemDefaultDevice
        }
        return try RenderDevice(device: device)
    }

    /// Emit the capability set. Called once from `init`; safe to call again manually.
    public func logCapabilities() {
        Self.log.notice("Metal device initialised:\n\(self.capabilities.description, privacy: .public)")
        if !capabilities.supportsBCTextureCompression {
            // Worth shouting about: without hardware BC we would have to transcode
            // every DXT texture to RGBA8, which is both a large VRAM increase and a
            // multi-second CPU cost per wallpaper import.
            Self.log.warning("Device lacks BC texture compression; DXT content will need transcoding.")
        }
        if capabilities.appleFamilyLevel == 0 {
            Self.log.warning("Device does not satisfy MTLGPUFamily.apple7; performance targets assume Apple Silicon.")
        }
    }

    /// Create a command buffer for one frame.
    ///
    /// Uses the unretained-references variant: the renderer keeps strong references to
    /// every resource a frame touches for the life of the frame anyway (they live in the
    /// pool, the caches, and the retained graph), so paying Metal to retain and release
    /// each one again per encode is pure overhead — it is a measurable slice of encode
    /// time on a graph with many nodes.
    ///
    /// - Important: only call this if the above invariant holds. If you encode a
    ///   resource that nothing else keeps alive, use ``makeRetainedCommandBuffer()``.
    public func makeFrameCommandBuffer(label: String? = nil) -> (any MTLCommandBuffer)? {
        let buffer = commandQueue.makeCommandBufferWithUnretainedReferences()
        buffer?.label = label
        return buffer
    }

    /// A conventional, resource-retaining command buffer. Use for one-off work such as
    /// texture uploads, where the staging buffer has no other owner.
    public func makeRetainedCommandBuffer(label: String? = nil) -> (any MTLCommandBuffer)? {
        let buffer = commandQueue.makeCommandBuffer()
        buffer?.label = label
        return buffer
    }
}
