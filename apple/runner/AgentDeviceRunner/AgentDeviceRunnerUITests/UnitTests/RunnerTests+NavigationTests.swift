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

  /// The verification samples the screen, not the accessibility tree, so a tree XCTest cannot read
  /// still yields a verified answer through the sole screen: a swipe the app answers is performed,
  /// and one it ignores is the typed no-change refusal, never a false success.
  @MainActor
  func testInAppBackOnAnUnreadableTreeVerifiesTheSwipeOnTheSoleScreen() throws {
    let status = try launchBackFixture(["--agent-device-back-regression"])
    // Terminates whichever fixture instance is running when the test leaves, on every path.
    defer { endBackFixture() }
    let answered = try withRejectedAppTree(framesReadable: false) { try performInAppBack(app: app) }
    let soleScreenOpen = soleScreenRouteIsOpen(for: app)
    let answeredLabel = status.label
    endBackFixture()
    _ = try launchBackFixture([])
    let ignored = try withRejectedAppTree(framesReadable: false) { try performInAppBack(app: app) }

    guard soleScreenOpen else {
      guard case .refused = answered, case .refused = ignored else {
        return XCTFail("without a window or a sole screen there is nothing to verify, so back must not swipe")
      }
      return
    }
    guard case .performed = answered else {
      return XCTFail("a swipe the app answered must verify on the sole screen")
    }
    XCTAssertEqual(answeredLabel, "Back performed")
    guard case .unconfirmed(let payload) = ignored else {
      return XCTFail("a swipe the app ignored must not read as performed")
    }
    XCTAssertEqual(payload.code, RunnerWireErrorCode.backSwipeNoChange)
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
    XCTAssertEqual(interrupted.code, "UNSUPPORTED_OPERATION")
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
    let captured: Sample = .success(Data(repeating: 0, count: 100))
    let changed: Sample = .success(Data(repeating: 255, count: 100))
    let other: Sample = .success(Data(repeating: 0, count: 100))

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
    let base = Data(repeating: 100, count: 1000)
    var spinner = base
    for index in 0..<5 { spinner[index] = 255 }
    let shimmer = Data(repeating: 120, count: 1000)
    var pushed = base
    for index in 0..<300 { pushed[index] = 255 }

    XCTAssertFalse(Self.visualSamplesDiffer(base, spinner), "0.5% of cells is not navigation")
    XCTAssertFalse(Self.visualSamplesDiffer(base, shimmer), "every cell moving by 20 stays inside the tolerance")
    XCTAssertTrue(Self.visualSamplesDiffer(base, pushed), "30% of cells redrawn is navigation")
    XCTAssertTrue(Self.visualSamplesDiffer(base, Data(repeating: 100, count: 999)), "a different grid size is uncomparable")
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
