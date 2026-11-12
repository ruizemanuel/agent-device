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
    switch try dispatchScreenEdgeTouch(app: app, plan: plan) {
    case .sent:
      return .performed
    case .notSent(let message, let hint), .interrupted(let message, let hint):
      return .unsupported(message: message, hint: hint)
    }
  }

  /// The edge touch and whether it reached the device: every refusal before touch-down is `.notSent`.
  @MainActor
  private func dispatchScreenEdgeTouch(app: XCUIApplication, plan: RunnerGesturePlan) throws -> TouchDispatch {
    // The coordinate context books a foldable's lit-panel window and keeps its typed refusal.
    let planned: NativePlannedGesture
    switch try nativePlannedGesture(app: app, plan: plan, gesture: "edge swipe") {
    case .resolved(let resolved): planned = resolved
    case .refused(let outcome): return TouchDispatch(notSent: outcome)
    }
    guard let portraitSize = edgeTouchDisplayPortraitSize(), let samples = planned.pointerSamples.first else {
      return TouchDispatch(notSent: Self.unmeasuredSoleDisplayOutcome(gesture: "edge swipe"))
    }
    var touchDown: ObjCBool = false
    if let message = RunnerSimulatorEdgeTouch.dispatch(
      withApplication: app,
      resolvedWindow: planned.context.resolvedWindow,
      samples: samples,
      screenSize: portraitSize,
      touchDown: &touchDown
    ) {
      let hint = "Retry after the app is foregrounded on a simulator display with a touchscreen."
      return touchDown.boolValue
        ? .interrupted(message: message, hint: hint)
        : .notSent(message: message, hint: hint)
    }
    return .sent
  }

  /// The left-edge back swipe as the `right-edge` gesture preset plans it: from 8 pt inside the
  /// leading edge to 85% of the width at mid-height, in 100 ms.
  @MainActor
  func screenEdgeBackSwipe(app: XCUIApplication, surface: CGRect) throws -> TouchDispatch {
    let y = Double(surface.midY)
    let samples = [
      RunnerGestureSample(offsetMs: 0, point: RunnerGesturePoint(x: Double(surface.minX + 8), y: y)),
      RunnerGestureSample(
        offsetMs: 100,
        point: RunnerGesturePoint(x: Double(surface.minX + surface.width * 0.85), y: y)
      ),
    ]
    return try dispatchScreenEdgeTouch(app: app, plan: RunnerGesturePlan(
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
