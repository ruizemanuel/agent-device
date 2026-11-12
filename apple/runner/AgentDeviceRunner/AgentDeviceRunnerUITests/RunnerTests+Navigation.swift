import AgentDeviceSnapshotPresentation
import XCTest

extension RunnerTests {
  static let backSwipeVerificationDelay: TimeInterval = 0.25
  static let backSwipeSettleSamples = 4

  /// What one `back` concluded. `.refused` dispatched nothing. `.unconfirmed` ran the back gesture,
  /// or may have, without proof that it navigated back.
  enum InAppBackOutcome {
    case performed
    case refused(ErrorPayload)
    case unconfirmed(ErrorPayload)
  }

  /// The three answers a before/after visual comparison can give. `unobserved` carries the typed
  /// refusal that made the pair uncomparable: a display that refuses to be sampled proves nothing
  /// either way, and reading it as "unchanged" would claim the swipe did nothing.
  enum NavigationVisualObservation: Equatable {
    case changed
    case unchanged
    case unobserved(refusal: RunnerAppScreenCaptureFailure)

    var logToken: String {
      switch self {
      case .changed: return "yes"
      case .unchanged: return "no"
      case .unobserved: return "unknown"
      }
    }
  }

  /// iOS `back` is the left-edge back swipe, verified by a change of the app's screen. A visible
  /// back control is the caller's to press by ref; the runner does not guess at buttons.
  @MainActor
  func performInAppBack(app: XCUIApplication) throws -> InAppBackOutcome {
#if os(macOS)
    guard let back = macOSNavigationBackElement(app: app) else {
      return .refused(ErrorPayload(message: "in-app back control is not available"))
    }
    let frame = back.frame
    if frame.isEmpty {
      back.tap()
    } else {
      _ = try tapAt(app: app, x: frame.midX, y: frame.midY)
    }
    return .performed
#elseif os(tvOS)
    _ = pressTvRemote(.menu)
    return .performed
#else
    guard let context = try synthesizedCoordinateContext(app: app) else {
      return .refused(Self.backScreenRefusal(.unresolvedWindow))
    }
    let before: (sample: Data, settled: Bool)
    switch settledBackVisualState(app: app, context: context) {
    case .success(let settled): before = settled
    case .failure(let refusal): return .refused(Self.backScreenRefusal(refusal))
    }
    if case .unsupported(let message, let hint) = try performBackGesture(
      app: app,
      surface: context.geometry.windowOnScreen.rect
    ) {
      return .unconfirmed(ErrorPayload(code: "UNSUPPORTED_OPERATION", message: message, hint: hint))
    }
    guard before.settled else {
      return .unconfirmed(
        Self.backSwipeUnverified(
          because: "the app's screen was already changing on its own",
          hint: "Take a snapshot to see where the app is."
        )
      )
    }
    sleepFor(Self.backSwipeVerificationDelay)
    let observation = Self.navigationVisualObservation(
      before: .success(before.sample),
      after: captureBackVisualState(app: app, context: context)
    )
    NSLog("AGENT_DEVICE_RUNNER_BACK_SWIPE_VERIFICATION changed=%@", observation.logToken)
    return Self.backSwipeOutcome(observation: observation)
#endif
  }

  /// No screen to compare means no proof either way, so the swipe is not sent.
  static func backScreenRefusal(_ refusal: RunnerAppScreenCaptureFailure) -> ErrorPayload {
    ErrorPayload(
      code: refusal.rawValue,
      message: "back did not swipe: the app's screen could not be sampled to verify it.",
      hint: refusal.hint
    )
  }

  /// Samples until two frames a verification delay apart agree, so a screen still changing on its
  /// own, such as one still rendering after a launch, is not read as the swipe's effect. `settled`
  /// is false when the samples ran out first.
  private func settledBackVisualState(
    app: XCUIApplication,
    context: SynthesizedCoordinateContext
  ) -> Result<(sample: Data, settled: Bool), RunnerAppScreenCaptureFailure> {
    var previous: Data
    switch captureBackVisualState(app: app, context: context) {
    case .success(let sample): previous = sample
    case .failure(let refusal): return .failure(refusal)
    }
    for _ in 0..<Self.backSwipeSettleSamples {
      sleepFor(Self.backSwipeVerificationDelay)
      switch captureBackVisualState(app: app, context: context) {
      case .success(let next) where next == previous: return .success((next, true))
      case .success(let next): previous = next
      case .failure(let refusal): return .failure(refusal)
      }
    }
    return .success((previous, false))
  }

  /// The frame the swipe compares, encoded when the display answered and the typed refusal
  /// otherwise. It samples the app's own screen only: a system-surface capture reads as "unchanged"
  /// across a before/after pair and launders a wrong-process frame into a false refusal.
  private func captureBackVisualState(
    app: XCUIApplication,
    context: SynthesizedCoordinateContext
  ) -> Result<Data, RunnerAppScreenCaptureFailure> {
#if os(iOS)
    return Self.navigationVisualSample(
      // A lit-panel request never takes the sole-screen route: a foldable has no sole screen.
      from: context.resolvedWindow == nil && requestLitPanel == nil
        ? captureSoleAppScreen(app: app)
        : captureResolvedAppScreen(app: app, litPanel: requestLitPanel),
      encoding: { runnerPngData(for: $0.image) }
    )
#else
    return .failure(.unresolvedScreen)
#endif
  }

  /// Turns a capture answer into the bytes to compare. A resolved display whose image would not
  /// encode is named as the capture failure it is, not as an unnamed no-sample that would default to
  /// "no display resolved". Kept apart from the query so the mapping itself is testable.
  static func navigationVisualSample(
    from captured: Result<CapturedAppScreen, RunnerAppScreenCaptureFailure>,
    encoding: (CapturedAppScreen) -> Data?
  ) -> Result<Data, RunnerAppScreenCaptureFailure> {
    captured.flatMap { screen in
      guard let png = encoding(screen) else { return .failure(.unrenderableImage) }
      return .success(png)
    }
  }

  /// What an observation of the swipe's before/after samples concludes. Kept apart from the sleep
  /// and the capture so the three-way decision is testable without a running app.
  static func backSwipeOutcome(observation: NavigationVisualObservation) -> InAppBackOutcome {
    switch observation {
    case .changed:
      return .performed
    case .unchanged:
      return .unconfirmed(
        ErrorPayload(
          code: RunnerWireErrorCode.backSwipeNoChange,
          message: "The back swipe changed nothing.",
          hint: "Press the visible back or close control by its ref from a fresh snapshot."
        )
      )
    case .unobserved(let refusal):
      return .unconfirmed(
        backSwipeUnverified(because: "the app's screen could not be sampled afterwards", hint: refusal.hint)
      )
    }
  }

  static func backSwipeUnverified(because reason: String, hint: String?) -> ErrorPayload {
    ErrorPayload(
      code: RunnerWireErrorCode.backSwipeUnverified,
      message: "The back swipe ran, but \(reason). This is an unknown outcome.",
      hint: hint
    )
  }

  static func navigationVisualObservation(
    before: Result<Data, RunnerAppScreenCaptureFailure>,
    after: Result<Data, RunnerAppScreenCaptureFailure>
  ) -> NavigationVisualObservation {
    switch (before, after) {
    case (.success(let before), .success(let after)):
      return before != after ? .changed : .unchanged
    // The refusal most recently hit names the unknown. An uncomparable pair always carries one.
    case (_, .failure(let refusal)):
      return .unobserved(refusal: refusal)
    case (.failure(let refusal), _):
      return .unobserved(refusal: refusal)
    }
  }

  private func macOSNavigationBackElement(app: XCUIApplication) -> XCUIElement? {
    let predicate = NSPredicate(
      format: "identifier == %@ OR label == %@",
      "go back",
      "Back"
    )
    let element = app.descendants(matching: .any).matching(predicate).firstMatch
    return element.exists ? element : nil
  }
}
