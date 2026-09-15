//
//  RenderActor.swift
//  MetalRenderer
//
//  The module's threading contract, expressed as a type the compiler can check.
//

import Dispatch

/// The serial execution context that owns every mutable renderer object.
///
/// ## Why a custom global actor rather than `MainActor` or a bare `DispatchQueue`
///
/// A wallpaper renderer must never contend with the UI. If frame encode ran on
/// `MainActor` it would be scheduled behind SwiftUI layout, AppKit event handling,
/// and every other main-thread client in the process — turning a 0.4 ms encode into
/// an unpredictable multi-millisecond stall and, worse, making the app's window
/// responsiveness a function of wallpaper complexity.
///
/// So the render loop lives on its own serial queue. Expressing that queue as a
/// `@globalActor` (rather than leaving it as an undocumented `DispatchQueue` that
/// callers are expected to remember) buys three things:
///
/// 1. **Compile-time enforcement.** `@RenderActor` types simply cannot be touched
///    from the wrong context without an `await`. The threading contract stops being
///    a comment nobody reads.
/// 2. **Free mutable state.** Metal command encoders, the FBO pool's free lists, and
///    the caches are all mutable and none of them are thread-safe. Serial isolation
///    means no locks on the hot path — and no lock means no chance of the render
///    thread blocking on a priority-inverted UI thread.
/// 3. **Cheap re-entry.** Successive `await` calls that are already on this actor do
///    not hop or allocate, so a frame is one hop in and then straight-line work.
///
/// ## Contract for callers
///
/// - Renderer objects (`FBOPool`, `TextureCache`, `PipelineCache`, `RenderGraph`,
///   `Quad`, `FrameTimer`) are `@RenderActor`-isolated. Create and use them here.
/// - `RenderDevice` and every `…Stats`/`Snapshot` value type is `Sendable` and
///   `nonisolated`, so a diagnostics HUD on `MainActor` can read them with a single
///   `await` and no shared mutable state.
/// - Do **not** block this actor. A `waitUntilCompleted()` on the render actor stalls
///   every display's render loop, not just one.
///
/// The underlying queue runs at `.userInteractive` because it is driven by a display
/// link: missing the deadline is a visible stutter, and the work is small and bounded.
@globalActor
public actor RenderActor {

    public static let shared = RenderActor()

    /// The queue backing this actor. Exposed so that code which must still use
    /// callback-based Metal or Core Animation APIs (`CADisplayLink`, command-buffer
    /// completion handlers) can target the same serial context.
    public nonisolated let queue = DispatchSerialQueue(
        label: "com.diorama.metalrenderer.render",
        qos: .userInteractive
    )

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private init() {}

    /// Debug-only check that the caller really is on the render queue.
    ///
    /// Isolation already guarantees this for Swift callers; this exists for the
    /// boundary where a C or Objective-C callback (a display link, a completion
    /// handler) claims to be dispatching onto `queue`.
    public nonisolated static func assertIsolated(
        _ message: @autoclosure () -> String = "must run on the render queue",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(RenderActor.shared.queue))
        #endif
        _ = message
        _ = file
        _ = line
    }
}
