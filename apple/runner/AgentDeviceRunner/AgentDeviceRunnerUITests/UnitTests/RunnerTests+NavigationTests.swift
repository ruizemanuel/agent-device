import XCTest
#if AGENT_DEVICE_RUNNER_UNIT_TESTS && os(iOS)
import ObjectiveC.runtime
#endif

#if AGENT_DEVICE_RUNNER_UNIT_TESTS
extension RunnerTests {
#if os(iOS)
  @MainActor
  func testInAppBackSwipesFromTheLeftEdgeAndVerifiesTheChange() throws {
    let status = try launchBackFixture(["--agent-device-back-regression"])
    defer { endBackFixture() }

    guard case .performed = try performInAppBack(app: app) else {
      return XCTFail("a left-edge swipe the app answers must read as performed")
    }
    XCTAssertEqual(status.label, "Back performed")
  }

  /// A swipe the app ignores leaves the screen unchanged, so back refuses with the typed reason and
  /// a hint to press the visible control instead.
  @MainActor
  func testInAppBackReportsASwipeThatChangedNothing() throws {
    _ = try launchBackFixture([])
    defer { endBackFixture() }

    let response = try execute(command: try runnerCommandFixture(
      #"{"command":"backInApp","commandId":"back-no-change","appBundleId":"com.callstack.agentdevice.runner"}"#
    ))
    XCTAssertEqual(response.error?.code, RunnerWireErrorCode.backSwipeNoChange)
    XCTAssertNotNil(response.error?.hint)
  }

  /// A screen that changes on its own would read as a back navigation, so back reports an unknown
  /// outcome there, never success.
  @MainActor
  func testInAppBackOnAScreenThatKeepsChangingReportsAnUnknownOutcome() throws {
    _ = try launchBackFixture(["--agent-device-back-regression", "--animating"])
    defer { endBackFixture() }

    guard case .unconfirmed(let payload) = try performInAppBack(app: app) else {
      return XCTFail("a screen that changes on its own must not read as performed")
    }
    XCTAssertEqual(payload.code, RunnerWireErrorCode.backSwipeUnverified)
  }

  /// A screen that changes on its own every 0.5 s gives one quiet pair of samples 0.25 s apart, then
  /// changes before the after sample. Settling needs three agreeing samples, so it is never settled
  /// and back reports an unknown outcome instead of crediting the swipe.
  @MainActor
  func testInAppBackOnAScreenChangingSlowerThanOneDelayIsNotPerformed() throws {
    _ = try launchBackFixture(["--agent-device-back-regression", "--slow-toggle"])
    defer { endBackFixture() }

    guard case .unconfirmed(let payload) = try performInAppBack(app: app) else {
      return XCTFail("a screen that toggles on its own must not read as performed")
    }
    XCTAssertEqual(payload.code, RunnerWireErrorCode.backSwipeUnverified)
  }

  @MainActor
  func testInAppBackDoesNotSwipeOffTheLitPanel() throws {
    let status = try launchBackFixture(["--agent-device-back-regression"])
    defer {
      setRequestLitPanel(from: try! runnerCommandFixture(#"{"command":"uptime"}"#))
      endBackFixture()
    }
    setRequestLitPanel(from: try runnerCommandFixture(
      #"{"command":"backInApp","litPanel":{"displayId":999,"widthPt":669,"heightPt":951}}"#
    ))
    XCTAssertThrowsError(try performInAppBack(app: app)) {
      XCTAssertEqual($0 as? RunnerAppScreenCaptureFailure, .offLitPanel)
    }
    assertBackNeverPerformed(status)
  }

  /// A hidden status bar (landscape, full-screen video, an RN screen that hides it) changes nothing:
  /// the comparison always leaves the same top band out, so back swipes and verifies as anywhere else.
  @MainActor
  func testInAppBackWithAHiddenStatusBarIsPerformed() throws {
    let status = try launchBackFixture(["--agent-device-back-regression", "--hide-status-bar"])
    defer { endBackFixture() }

    guard case .performed = try performInAppBack(app: app) else {
      return XCTFail("a screen without a status bar must still swipe and verify")
    }
    XCTAssertEqual(status.label, "Back performed")
  }

  /// The route witness: after the app's tree rejects the windows query, back reaches the screen
  /// through whichever route opens (the sole screen where the app proves it fills it), swipes, and
  /// verifies the change there.
  @MainActor
  func testInAppBackAfterARejectedQuerySwipesAndVerifiesOnTheRouteThatOpens() throws {
    let status = try launchBackFixture(["--agent-device-back-regression"])
    defer { endBackFixture() }

    let outcome = try withRejectedAppTree(framesReadable: true, rejections: 1) {
      try performInAppBack(app: app)
    }

    guard case .performed = outcome else {
      return XCTFail("back must swipe and verify through the route that opens after a rejected query")
    }
    XCTAssertEqual(status.label, "Back performed")
  }

  /// Only a swipe refused before touch-down is the not-dispatched refusal; one cut short after its
  /// touch-down may have navigated and stays an unknown outcome.
  func testBackGestureRefusalSeparatesNotSentFromInterrupted() {
    XCTAssertNil(Self.backGestureRefusal(.sent))
    guard case .refused(let notSent) = Self.backGestureRefusal(.notSent(message: "no touchscreen", hint: nil)) else {
      return XCTFail("a swipe that never touched down must refuse as not dispatched")
    }
    XCTAssertEqual(notSent.code, RunnerWireErrorCode.backSwipeNotDispatched)
    guard case .unconfirmed(let interrupted) = Self.backGestureRefusal(.interrupted(message: "lift failed", hint: nil))
    else {
      return XCTFail("a swipe cut short after touch-down must not claim nothing was dispatched")
    }
    // It may already have navigated, so it is the unknown outcome, never a retryable refusal.
    XCTAssertEqual(interrupted.code, RunnerWireErrorCode.backSwipeUnverified)
    XCTAssertTrue(interrupted.hint?.contains("snapshot") == true)
  }

  /// Fails when the fixture reports a back within a short window, so a gesture the app handles
  /// after the call returned still fails the test.
  @MainActor
  private func assertBackNeverPerformed(_ status: XCUIElement) {
    let performed = expectation(for: NSPredicate(format: "label == %@", "Back performed"), evaluatedWith: status)
    performed.isInverted = true
    wait(for: [performed], timeout: 1)
  }

  /// Launches the runner app and waits for its fixture surface. With
  /// `--agent-device-back-regression` a left-edge swipe sets the status to "Back performed", and
  /// without it the app ignores the swipe.
  @MainActor
  private func launchBackFixture(_ arguments: [String]) throws -> XCUIElement {
    app.launchArguments = arguments
    app.launch()
    mainOwned.app = app
    mainOwned.bundleId = "com.callstack.agentdevice.runner"
    clearSnapshotXCTestChannelPenalty(reason: "navigation-test")
    let status = arguments.contains("--agent-device-back-regression")
      ? app.staticTexts["agent-device-back-status"]
      : app.staticTexts.element(matching: NSPredicate(format: "label == %@", "Agent Device Runner"))
    XCTAssertTrue(status.waitForFixtureExistence(timeout: appExistenceTimeout))
    return status
  }
  @MainActor
  private func endBackFixture() {
    invalidateCachedTarget(reason: "unit_test_cleanup")
    app.terminate()
  }

  /// Stands in for XCTest on a tree it cannot serialize while `body` runs: the first `rejections`
  /// queries record the rejection the runner suppresses and find nothing, and unless
  /// `framesReadable`, every element frame reads empty.
  @MainActor
  private func withRejectedAppTree<T>(
    framesReadable: Bool,
    rejections: Int = .max,
    _ body: () throws -> T
  ) throws -> T {
    var restorations: [() -> Void] = []
    defer { restorations.reversed().forEach { $0() } }
    let selector = NSSelectorFromString("allElementsBoundByIndex")
    let query = try XCTUnwrap(class_getInstanceMethod(XCUIElementQuery.self, selector))
    let originalQuery = method_getImplementation(query)
    var remainingRejections = rejections
    let rejectedQuery = imp_implementationWithBlock({ (target: AnyObject) -> NSArray in
      guard remainingRejections > 0 else {
        typealias Query = @convention(c) (AnyObject, Selector) -> NSArray
        return unsafeBitCast(originalQuery, to: Query.self)(target, selector)
      }
      remainingRejections -= 1
      self.record(XCTIssue(type: .assertionFailure, compactDescription: "Failed to resolve query: kAXErrorIllegalArgument"))
      return []
    } as @convention(block) (AnyObject) -> NSArray)
    method_setImplementation(query, rejectedQuery)
    restorations.append {
      method_setImplementation(query, originalQuery)
      imp_removeBlock(rejectedQuery)
    }
    if !framesReadable {
      let frame = try XCTUnwrap(class_getInstanceMethod(XCUIElement.self, NSSelectorFromString("frame")))
      let originalFrame = method_getImplementation(frame)
      let unavailableFrame = imp_implementationWithBlock({ (_: AnyObject) -> CGRect in .zero } as @convention(block) (AnyObject) -> CGRect)
      method_setImplementation(frame, unavailableFrame)
      restorations.append {
        method_setImplementation(frame, originalFrame)
        imp_removeBlock(unavailableFrame)
      }
    }
    return try body()
  }

#endif

  func testNavigationVisualObservationSeparatesChangeFromRefusal() {
    // A refused side makes the pair uncomparable, not "unchanged"; reading it as "unchanged" would
    // let a capture that refused become the reason `back` claims its swipe changed nothing.
    // When both refuse, the later refusal names what back last looked at before giving up.
    typealias Sample = Result<Data, RunnerAppScreenCaptureFailure>
    let refused: Sample = .failure(.unresolvedScreen)
    let windowless: Sample = .failure(.unresolvedWindow)
    let captured: Sample = .success(grid(0))
    let changed: Sample = .success(grid(255))
    let other: Sample = .success(grid(0))

    XCTAssertEqual(Self.navigationVisualObservation(before: captured, after: changed), .changed, "changed")
    XCTAssertEqual(Self.navigationVisualObservation(before: captured, after: captured), .unchanged, "unchanged")
    XCTAssertEqual(
      Self.navigationVisualObservation(before: refused, after: other),
      .unobserved(refusal: .unresolvedScreen),
      "before refused"
    )
    XCTAssertEqual(
      Self.navigationVisualObservation(before: other, after: windowless),
      .unobserved(refusal: .unresolvedWindow),
      "after refused"
    )
    XCTAssertEqual(
      Self.navigationVisualObservation(before: refused, after: windowless),
      .unobserved(refusal: .unresolvedWindow),
      "both refused: the later refusal wins"
    )
  }

  /// A back navigation redraws most of the screen; a spinner, a clock tick, or a low-contrast
  /// shimmer must not read as one, or as a screen that never settles.
  func testVisualSamplesDifferOnlyForNavigationSizedChange() {
    let base = grid(100)
    let below = Self.backCompareTopRowsIgnored * Self.visualGridSize.width
    var spinner = base
    for index in below..<(below + 20) { spinner[index] = 255 }
    let shimmer = grid(120)
    var pushed = base
    for index in below..<(below + 1500) { pushed[index] = 255 }

    XCTAssertFalse(Self.visualSamplesDiffer(base, spinner), "20 cells below the top band is not navigation")
    XCTAssertFalse(Self.visualSamplesDiffer(base, shimmer), "every cell moving by 20 stays inside the tolerance")
    XCTAssertTrue(Self.visualSamplesDiffer(base, pushed), "a third of the screen redrawn is navigation")
    XCTAssertTrue(Self.visualSamplesDiffer(base, base.dropLast()), "a different grid size is uncomparable")
  }

  /// The top band (status bar, clock, Dynamic Island) is never compared, so a clock tick or a status
  /// bar that appears or hides cannot count as a change, while the first row below it does.
  func testVisualSamplesIgnoreAChangeConfinedToTheTopBand() {
    let base = grid(100)
    let band = Self.backCompareTopRowsIgnored * Self.visualGridSize.width
    var clockTick = base
    for index in 0..<band { clockTick[index] = 255 }
    var firstRowBelow = base
    for index in band..<(band + Self.visualGridSize.width) { firstRowBelow[index] = 255 }

    XCTAssertFalse(Self.visualSamplesDiffer(base, clockTick), "every cell of the top band changed")
    XCTAssertTrue(Self.visualSamplesDiffer(base, firstRowBelow), "one full row below the band is over 1%")
  }

  /// The grid's first row is the top of the screen, so the ignored band is where the status bar is.
  func testVisualGridKeepsTheTopOfTheScreenFirst() throws {
    let width = 120, height = 240
    let context = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 1, alpha: 1)
    // CoreGraphics' origin is bottom-left, so the top 10% of the image is the high-y strip.
    context.fill(CGRect(x: 0, y: CGFloat(height) * 0.9, width: CGFloat(width), height: CGFloat(height) * 0.1))
    let image = try XCTUnwrap(context.makeImage())

    let cells = try XCTUnwrap(Self.visualGrid(of: image))

    XCTAssertGreaterThan(cells[0], 200, "the first grid row is the top of the screen")
    XCTAssertLessThan(cells[cells.count - 1], 50, "the last grid row is the bottom")
  }

  private func grid(_ value: UInt8) -> Data {
    Data(repeating: value, count: Self.visualGridSize.width * Self.visualGridSize.height)
  }

  /// The runner's back swipe and the host's `right-edge` preset read the same golden table.
  func testBackSwipeEndpointsMatchTheHostRightEdgePreset() throws {
    let cases = try XCTUnwrap(runnerContractFixture("back-swipe-geometry.json") as? [[String: Any]])
    XCTAssertFalse(cases.isEmpty)
    func point(_ value: Any?) throws -> CGPoint {
      let object = try XCTUnwrap(value as? [String: Double])
      return CGPoint(x: try XCTUnwrap(object["x"]), y: try XCTUnwrap(object["y"]))
    }
    for fixture in cases {
      let name = fixture["name"] as? String ?? "?"
      let surface = try XCTUnwrap(fixture["surface"] as? [String: Double], name)
      let rect = CGRect(
        x: try XCTUnwrap(surface["x"]), y: try XCTUnwrap(surface["y"]),
        width: try XCTUnwrap(surface["width"]), height: try XCTUnwrap(surface["height"])
      )
      let endpoints = Self.backSwipeEndpoints(in: rect)
      XCTAssertEqual(endpoints.start, try point(fixture["start"]), name)
      XCTAssertEqual(endpoints.end, try point(fixture["end"]), name)
      XCTAssertEqual(Self.backSwipeDurationMs, fixture["durationMs"] as? Double, name)
    }
  }

  /// A swipe whose gap outran the time the screen had been still cannot tell its effect from a
  /// self-repaint slower than the window.
  func testBackSwipeGapIsCoveredOnlyByAsLongAStillWindow() {
    XCTAssertTrue(Self.backSwipeGapIsCovered(stableSinceMs: 0, justBeforeMs: 600, afterMs: 1100))
    XCTAssertTrue(Self.backSwipeGapIsCovered(stableSinceMs: 0, justBeforeMs: 600, afterMs: 1200))
    XCTAssertFalse(Self.backSwipeGapIsCovered(stableSinceMs: 0, justBeforeMs: 600, afterMs: 1300))
  }

  /// A screen that moved between settling and the swipe has no baseline to credit a change against.
  func testBackSwipeBaselineHoldsOnlyWhenSettledAndUnmovedBeforeTheSwipe() {
    let baseline = grid(100)
    let moved = grid(255)

    XCTAssertTrue(Self.backSwipeBaselineHolds(settled: true, baseline: baseline, justBefore: baseline))
    XCTAssertFalse(Self.backSwipeBaselineHolds(settled: true, baseline: baseline, justBefore: moved))
    XCTAssertFalse(Self.backSwipeBaselineHolds(settled: false, baseline: baseline, justBefore: baseline))
  }

  func testBackSwipeOutcomeNamesNoChangeAndAnUnsampledScreenApart() {
    switch Self.backSwipeOutcome(observation: .unchanged) {
    case .unconfirmed(let payload):
      XCTAssertEqual(payload.code, RunnerWireErrorCode.backSwipeNoChange)
    case .performed, .refused:
      XCTFail("an unchanged screen must refuse with the no-change reason")
    }
    // A screen that refused to be sampled after the swipe is an unknown outcome, never a success.
    switch Self.backSwipeOutcome(observation: .unobserved(refusal: .unresolvedWindow)) {
    case .unconfirmed(let payload):
      XCTAssertEqual(payload.code, RunnerWireErrorCode.backSwipeUnverified)
      XCTAssertEqual(payload.hint, RunnerAppScreenCaptureFailure.unresolvedWindow.hint)
      XCTAssertTrue(payload.message.contains("unknown outcome"))
    case .performed, .refused:
      XCTFail("an unsampled screen after the swipe must report an unknown outcome")
    }
  }

  func testNavigationVisualSampleDistinguishesEncodedFrameFromRefusal() {
    // The same capture entry point yields three different answers, and only the refusals carry a
    // reason: an encoded frame is evidence, a resolved-but-unencodable image and a refusal are not.
    // Reverting the mapping to a plain no-sample loses the code a host keys on.
    let captured = CapturedAppScreen(
      image: RunnerImage(),
      displayID: 3,
      pixelWidth: 12,
      pixelHeight: 24,
      pixelsPerPoint: 3
    )

    XCTAssertEqual(
      Self.navigationVisualSample(from: .success(captured), encoding: { _ in Data([7, 7]) }),
      .success(Data([7, 7]))
    )
    XCTAssertEqual(
      Self.navigationVisualSample(from: .success(captured), encoding: { _ in nil }),
      .failure(.unrenderableImage)
    )
    XCTAssertEqual(
      Self.navigationVisualSample(from: .failure(.unresolvedScreen), encoding: { _ in Data([7, 7]) }),
      .failure(.unresolvedScreen)
    )
  }
}
#endif
