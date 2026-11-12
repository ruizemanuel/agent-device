import AgentDeviceSnapshotPresentation
import XCTest

extension RunnerTests {
  static let backSwipeVerificationDelay: TimeInterval = 0.25
  /// Three agreeing samples span two verification delays, at least the gap from the last before
  /// sample to the after sample, so a screen that changes on its own more slowly than one delay
  /// cannot pass for settled and then read as the swipe's effect.
  static let backSwipeStableSamples = 3
  static let backSwipeSettleSampleBudget = 6

  /// What one `back` concluded. `.refused` dispatched nothing. `.unconfirmed` ran the back gesture,
  /// or may have, without proof that it navigated back.
  enum InAppBackOutcome {
    case performed
    case refused(ErrorPayload)
    case unconfirmed(ErrorPayload)
  }

  /// The back swipe's duration, the `right-edge` preset's `GESTURE_FLING_DURATION_MS`.
  static let backSwipeDurationMs = 100.0

  /// The back swipe's endpoints across `surface`. Mirrors the `right-edge` fling preset
  /// (`buildSwipePresetGesturePlan` and `clampGestureCoordinate` in packages/contracts/src/scroll-gesture.ts):
  /// 1% to 85% of the width at half the height, truncated, then held 8 pt inside the edges.
  /// contracts/fixtures/back-swipe-geometry.json holds both sides to the same table.
  static func backSwipeEndpoints(in surface: CGRect) -> (start: CGPoint, end: CGPoint) {
    func axis(_ size: CGFloat, percent: CGFloat) -> CGFloat {
      let margin: CGFloat = 8
      let upper = max(margin, (size - margin).rounded())
      return min(upper, max(margin, (size * percent / 100).rounded(.towardZero)))
    }
    let y = surface.minY + axis(surface.height, percent: 50)
    return (
      CGPoint(x: surface.minX + axis(surface.width, percent: 1), y: y),
      CGPoint(x: surface.minX + axis(surface.width, percent: 85), y: y)
    )
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
#elseif os(iOS)
    guard let context = try synthesizedCoordinateContext(app: app) else {
      return .refused(Self.backScreenRefusal(.unresolvedWindow))
    }
    guard let statusBarHeight = backStatusBarHeight(app: app, context: context) else {
      return .refused(
        ErrorPayload(
          code: RunnerWireErrorCode.backSwipeNotDispatched,
          message: "back did not swipe: the app's status bar could not be read, so its screen cannot be compared.",
          hint: "Press the visible back or close control by its ref."
        )
      )
    }
    let before: (sample: Data, settled: Bool)
    switch settledBackVisualState(app: app, context: context, statusBarHeight: statusBarHeight) {
    case .success(let settled): before = settled
    case .failure(let refusal): return .refused(Self.backScreenRefusal(refusal))
    }
    // One more sample right before the swipe: the change credited to the swipe is measured from it.
    let justBefore: Data
    switch captureBackVisualState(app: app, context: context, statusBarHeight: statusBarHeight) {
    case .success(let sample): justBefore = sample
    case .failure(let refusal): return .refused(Self.backScreenRefusal(refusal))
    }
    let stillSettled = Self.backSwipeBaselineHolds(
      settled: before.settled,
      baseline: before.sample,
      justBefore: justBefore
    )
    if let refusal = Self.backGestureRefusal(try performBackGesture(app: app, context: context)) {
      return refusal
    }
    guard stillSettled else {
      return .unconfirmed(
        Self.backSwipeUnverified(
          because: "the app's screen was already changing on its own",
          hint: "Take a snapshot to see where the app is."
        )
      )
    }
    sleepFor(Self.backSwipeVerificationDelay)
    let observation = Self.navigationVisualObservation(
      before: .success(justBefore),
      after: captureBackVisualState(app: app, context: context, statusBarHeight: statusBarHeight)
    )
    NSLog("AGENT_DEVICE_RUNNER_BACK_SWIPE_VERIFICATION changed=%@", observation.logToken)
    return Self.backSwipeOutcome(observation: observation)
#else
    // visionOS has no edge swipe that pops a navigation stack.
    return .refused(
      ErrorPayload(
        code: RunnerWireErrorCode.backSwipeNotDispatched,
        message: "back has no gesture on this platform, so nothing was sent.",
        hint: "Press the visible back control by its ref."
      )
    )
#endif
  }

#if os(iOS)
  /// A swipe refused before touch-down reached nothing; one cut short after it may have navigated.
  static func backGestureRefusal(_ dispatch: TouchDispatch) -> InAppBackOutcome? {
    switch dispatch {
    case .sent:
      return nil
    case .notSent(let message, let hint):
      return .refused(ErrorPayload(code: RunnerWireErrorCode.backSwipeNotDispatched, message: message, hint: hint))
    case .interrupted(let message, _):
      return .unconfirmed(
        backSwipeUnverified(
          because: "it was cut short after it touched down (\(message))",
          hint: "Check the screen with snapshot before you retry; the swipe may already have navigated."
        )
      )
    }
  }
#endif

  /// No screen to compare means no proof either way, so the swipe is not sent.
  static func backScreenRefusal(_ refusal: RunnerAppScreenCaptureFailure) -> ErrorPayload {
    ErrorPayload(
      code: refusal.rawValue,
      message: "back did not swipe: the app's screen could not be sampled to verify it.",
      hint: refusal.hint
    )
  }

  /// Samples a verification delay apart until `backSwipeStableSamples` in a row agree with the
  /// first of them. `settled` is false when the budget ran out first.
  private func settledBackVisualState(
    app: XCUIApplication,
    context: SynthesizedCoordinateContext,
    statusBarHeight: CGFloat
  ) -> Result<(sample: Data, settled: Bool), RunnerAppScreenCaptureFailure> {
    var stableRun: [Data] = []
    for index in 0..<Self.backSwipeSettleSampleBudget {
      if index > 0 { sleepFor(Self.backSwipeVerificationDelay) }
      switch captureBackVisualState(app: app, context: context, statusBarHeight: statusBarHeight) {
      case .failure(let refusal):
        return .failure(refusal)
      case .success(let sample):
        if let first = stableRun.first, Self.visualSamplesDiffer(first, sample) {
          stableRun = [sample]
        } else {
          stableRun.append(sample)
        }
        if stableRun.count >= Self.backSwipeStableSamples { return .success((sample, true)) }
      }
    }
    return .success((stableRun[stableRun.count - 1], false))
  }

  /// The frame the swipe compares, below the status bar, as a coarse grayscale grid when the display
  /// answered and the typed refusal otherwise. It samples the app's own screen only: a system-surface
  /// capture reads as "unchanged" across a before/after pair and launders a wrong-process frame into
  /// a false refusal. The status bar changes on its own (the clock, signal, a recording indicator).
  private func captureBackVisualState(
    app: XCUIApplication,
    context: SynthesizedCoordinateContext,
    statusBarHeight: CGFloat
  ) -> Result<Data, RunnerAppScreenCaptureFailure> {
#if os(iOS)
    return Self.navigationVisualSample(
      // A lit-panel request never takes the sole-screen route: a foldable has no sole screen.
      from: context.resolvedWindow == nil && requestLitPanel == nil
        ? captureSoleAppScreen(app: app)
        : captureResolvedAppScreen(app: app, litPanel: requestLitPanel),
      encoding: { screen in
        let statusBar = statusBarHeight * CGFloat(screen.pixelsPerPoint)
        return runnerCGImage(from: screen.image).flatMap { Self.visualGrid(of: $0, excludingTop: statusBar) }
      }
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

  static let visualGridSize = (width: 48, height: 96)
  static let visualCellTolerance = 24
  static let visualChangedCellFraction = 0.01

#if os(iOS)
  /// The bottom of the status bar over the target app, in screen points, measured rather than read
  /// from the runner process: the app's own status bar element when its tree exposes one, else the
  /// SpringBoard status bar drawn over it. An unreadable app tree is not queried and goes straight to
  /// SpringBoard. Nil only when no status-bar frame can be read at all; then no sample can be
  /// compared, so back refuses.
  private func backStatusBarHeight(app: XCUIApplication, context: SynthesizedCoordinateContext) -> CGFloat? {
    let sources = context.treeUnreadable ? [springboard] : [app, springboard]
    for source in sources {
      let statusBar = source.statusBars.firstMatch
      guard statusBar.exists else { continue }
      let frame = statusBar.frame
      if SnapshotGeometry.isPositiveFinite(frame) { return frame.maxY }
    }
    return nil
  }
#endif

  /// The screen below its top `excludingTop` pixels, drawn into a small grayscale grid. A back
  /// navigation redraws most of it, while a spinner, a caret, or a material shimmer moves few
  /// cells or moves them by little.
  static func visualGrid(of fullImage: CGImage, excludingTop topPixels: CGFloat = 0) -> Data? {
    let top = min(max(topPixels, 0), CGFloat(fullImage.height - 1))
    guard let image = fullImage.cropping(
      to: CGRect(x: 0, y: top, width: CGFloat(fullImage.width), height: CGFloat(fullImage.height) - top)
    ) else { return nil }
    let (width, height) = visualGridSize
    var cells = [UInt8](repeating: 0, count: width * height)
    let drawn = cells.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      ) else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? Data(cells) : nil
  }

  /// Two grids differ when more than 1% of their cells moved by more than the tolerance.
  static func visualSamplesDiffer(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return true }
    let moved = zip(lhs, rhs).reduce(0) { count, pair in
      abs(Int(pair.0) - Int(pair.1)) > visualCellTolerance ? count + 1 : count
    }
    return Double(moved) > Double(lhs.count) * visualChangedCellFraction
  }

  /// Whether the swipe's effect can be measured: the screen settled, and the sample taken right
  /// before the swipe still matches the settled baseline.
  static func backSwipeBaselineHolds(settled: Bool, baseline: Data, justBefore: Data) -> Bool {
    settled && !visualSamplesDiffer(baseline, justBefore)
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
      return visualSamplesDiffer(before, after) ? .changed : .unchanged
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
