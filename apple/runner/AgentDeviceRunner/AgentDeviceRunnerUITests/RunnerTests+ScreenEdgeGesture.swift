import XCTest

/// The plan value for a contact that starts as a screen-edge touch. Mirrors
/// `GestureContactOrigin` in packages/contracts/src/gesture-plan-types.ts.
let runnerScreenEdgeContactOrigin = "screen-edge"

extension RunnerTests {
#if os(iOS) && targetEnvironment(simulator)
  /// Dispatches a screen-edge plan as one HID touch with the digitizer edge mask. XCTest
  /// synthesized touches never carry that mask, so UIKit edge recognizers ignore them.
  @MainActor
  func screenEdgePlannedGesture(
    app: XCUIApplication,
    plan: RunnerGesturePlan
  ) throws -> RunnerInteractionOutcome {
    // The coordinate context books a foldable's lit-panel window and keeps its typed refusal.
    let planned: NativePlannedGesture
    switch try nativePlannedGesture(app: app, plan: plan, gesture: "edge swipe") {
    case .resolved(let resolved): planned = resolved
    case .refused(let outcome): return outcome
    }
    guard let portraitSize = edgeTouchDisplayPortraitSize(), let samples = planned.pointerSamples.first else {
      return Self.unmeasuredSoleDisplayOutcome(gesture: "edge swipe")
    }
    if let message = RunnerSimulatorEdgeTouch.dispatch(
      withApplication: app,
      resolvedWindow: planned.context.resolvedWindow,
      samples: samples,
      screenSize: portraitSize
    ) {
      return .unsupported(
        message: message,
        hint: "Retry after the app is foregrounded on a simulator display with a touchscreen."
      )
    }
    return .performed
  }

  /// The left-edge back swipe as the `right-edge` gesture preset plans it: from 8 pt inside the
  /// leading edge to 85% of the width at mid-height, in 100 ms.
  @MainActor
  func screenEdgeBackSwipe(app: XCUIApplication, surface: CGRect) throws -> RunnerInteractionOutcome {
    let y = Double(surface.midY)
    let samples = [
      RunnerGestureSample(offsetMs: 0, point: RunnerGesturePoint(x: Double(surface.minX + 8), y: y)),
      RunnerGestureSample(
        offsetMs: 100,
        point: RunnerGesturePoint(x: Double(surface.minX + surface.width * 0.85), y: y)
      ),
    ]
    return try screenEdgePlannedGesture(app: app, plan: RunnerGesturePlan(
      topology: "single",
      intent: "fling",
      executionProfile: "endpoint-hold",
      contactOrigin: runnerScreenEdgeContactOrigin,
      durationMs: 100,
      viewport: RunnerGestureViewport(
        x: Double(surface.minX),
        y: Double(surface.minY),
        width: Double(surface.width),
        height: Double(surface.height)
      ),
      pointers: [RunnerGesturePointer(pointerId: 0, samples: samples)]
    ))
  }

  /// The portrait size of the display that hosts the app: the request's lit panel on a foldable,
  /// whose sides swap with the window's turn, else the sole screen.
  @MainActor
  private func edgeTouchDisplayPortraitSize() -> CGSize? {
    guard let panel = requestLitPanel else { return soleDisplayPortraitSize() }
    return CGSize(width: min(panel.widthPt, panel.heightPt), height: max(panel.widthPt, panel.heightPt))
  }
#endif
}
