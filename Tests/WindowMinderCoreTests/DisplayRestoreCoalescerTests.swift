import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class DisplayRestoreCoalescerTests: XCTestCase {
    func testWakeAndDisplayChangeRestoreOnce() {
        var script = Script()
        script.signal(.wake, at: 0)
        script.signal(.displayChange, at: 0.4)
        script.signal(.screensWake, at: 0.8)
        script.signal(.sessionUnlock, at: 1.1)
        XCTAssertEqual(script.deadline ?? -1, 1.1 + DisplayRestoreTiming.debounce, accuracy: 0.0001)

        let decision = script.settle(
            at: 1.1 + DisplayRestoreTiming.debounce,
            key: "desk",
            hasLayout: true,
            keyChanged: false
        )
        XCTAssertEqual(decision, .restore(key: "desk", generation: script.generation))
        XCTAssertEqual(script.restores, ["desk"])

        // The quiet timer already fired. A second evaluation is not another move.
        let again = script.coalescer.evaluate(script.generation, script.probe(
            key: "desk",
            hasLayout: true,
            autoRestore: true,
            drag: false,
            keyChanged: false,
            now: 3
        ))
        XCTAssertEqual(again, .skip)
        XCTAssertEqual(script.restores, ["desk"])
    }

    func testReconfigurationKeepsTheQuietPeriodOpen() {
        var script = Script()
        script.signal(.wake, at: 0)
        script.signal(.displayChange, at: 1.4)
        script.signal(.displayChange, at: 2.9)
        XCTAssertEqual(script.deadline ?? -1, 2.9 + DisplayRestoreTiming.debounce, accuracy: 0.0001)
        XCTAssertGreaterThan(script.deadline ?? 0, 1.5)

        let early = script.settle(at: 1.5, key: "desk", hasLayout: true, keyChanged: false)
        XCTAssertEqual(early, .skip)
        XCTAssertEqual(script.restores, [])

        let decision = script.settle(
            at: 2.9 + DisplayRestoreTiming.debounce,
            key: "desk",
            hasLayout: true,
            keyChanged: false
        )
        XCTAssertEqual(decision, .restore(key: "desk", generation: script.generation))
        XCTAssertEqual(script.restores, ["desk"])
    }

    func testAutoRestoreOffDoesNothing() {
        var script = Script()
        script.signal(.wake, at: 0)
        script.signal(.displayChange, at: 0.2)
        let decision = script.settle(
            at: 2,
            key: "desk",
            hasLayout: true,
            autoRestore: false,
            keyChanged: true
        )
        XCTAssertEqual(decision, .skip)
        XCTAssertEqual(script.restores, [])
    }

    func testMissingLayoutDoesNothing() {
        var script = Script()
        script.signal(.wake, at: 10)
        script.signal(.screensWake, at: 10.4)
        let decision = script.settle(
            at: 12,
            key: "desk",
            hasLayout: false,
            keyChanged: true
        )
        XCTAssertEqual(decision, .skip)
        XCTAssertEqual(script.restores, [])
    }

    func testDragDefersUntilThePointerIsReleased() {
        var coalescer = DisplayRestoreCoalescer()
        guard case .arm(let generation) = coalescer.note(.wake, at: 0) else {
            return XCTFail("Wake should arm one quiet wait")
        }
        let held = coalescer.evaluate(generation, probe(key: "desk", drag: true, keyChanged: false, now: 1.5))
        XCTAssertEqual(held, .deferUntilDragEnds(generation: generation))
        let stillHeld = coalescer.evaluate(generation, probe(key: "desk", drag: true, keyChanged: false, now: 2.2))
        XCTAssertEqual(stillHeld, .deferUntilDragEnds(generation: generation))

        let released = coalescer.evaluate(generation, probe(key: "desk", drag: false, keyChanged: false, now: 2.4))
        XCTAssertEqual(released, .restore(key: "desk", generation: generation))
        XCTAssertEqual(coalescer.evaluate(generation, probe(key: "desk", drag: false, keyChanged: false, now: 2.4)), .skip)
    }

    func testLaterDifferentDisplayKeyRestores() {
        var script = Script()
        script.signal(.wake, at: 0)
        script.signal(.displayChange, at: 0.3)
        let first = script.settle(at: 1.8, key: "laptop", hasLayout: true, keyChanged: false)
        XCTAssertEqual(first, .restore(key: "laptop", generation: script.generation))

        // Inside the same-setup window, a new setup is not swallowed by the wake.
        script.signal(.displayChange, at: 3)
        let second = script.settle(at: 3 + DisplayRestoreTiming.debounce, key: "desk", hasLayout: true, keyChanged: true)
        XCTAssertEqual(second, .restore(key: "desk", generation: script.generation))
        XCTAssertEqual(script.restores, ["laptop", "desk"])
    }

    func testSameSetupInsideTheCoalesceWindowDoesNotRestoreTwice() {
        var script = Script()
        script.signal(.wake, at: 0)
        _ = script.settle(at: 1.5, key: "desk", hasLayout: true, keyChanged: false)
        XCTAssertEqual(script.restores, ["desk"])

        script.signal(.screensWake, at: 2)
        script.signal(.displayChange, at: 2.2)
        let again = script.settle(at: 2.2 + DisplayRestoreTiming.debounce, key: "desk", hasLayout: true, keyChanged: false)
        XCTAssertEqual(again, .skip)
        XCTAssertEqual(script.restores, ["desk"])
    }

    func testDisplayChangeDuringRestoreFollowsANewKeyOnly() {
        var coalescer = DisplayRestoreCoalescer()
        guard case .arm(let generation) = coalescer.note(.wake, at: 0) else {
            return XCTFail("Wake should arm one quiet wait")
        }
        let first = coalescer.evaluate(generation, probe(key: "laptop", keyChanged: false, now: 1.5))
        XCTAssertEqual(first, .restore(key: "laptop", generation: generation))

        XCTAssertEqual(coalescer.note(.screensWake, at: 1.7), .coalesced(generation: generation))
        XCTAssertEqual(coalescer.note(.displayChange, at: 1.8), .coalesced(generation: generation))

        // The apply reads the same key, so the flicker is dropped.
        var sameKey = coalescer
        sameKey.cancelFollowUp()
        XCTAssertEqual(sameKey.restoreFinished(), .idle)

        guard case .arm(let follow) = coalescer.restoreFinished() else {
            return XCTFail("A display change during restore should arm one follow-up")
        }
        let same = coalescer.evaluate(follow, probe(key: "laptop", keyChanged: false, now: 4))
        XCTAssertEqual(same, .skip)

        var moved = DisplayRestoreCoalescer()
        guard case .arm(let armed) = moved.note(.wake, at: 0) else {
            return XCTFail("Wake should arm one quiet wait")
        }
        _ = moved.evaluate(armed, probe(key: "laptop", keyChanged: false, now: 1.5))
        _ = moved.note(.displayChange, at: 1.8)
        guard case .arm(let next) = moved.restoreFinished() else {
            return XCTFail("A changed display key should arm one follow-up")
        }
        let second = moved.evaluate(next, probe(key: "desk", keyChanged: true, now: 4))
        XCTAssertEqual(second, .restore(key: "desk", generation: next))
    }

    func testSessionUnlockAloneDoesNotRestoreAnUnchangedLayout() {
        var script = Script()
        script.signal(.sessionUnlock, at: 0)
        let unchanged = script.settle(at: 1.5, key: "desk", hasLayout: true, keyChanged: false)
        XCTAssertEqual(unchanged, .skip)
        XCTAssertEqual(script.restores, [])

        script.signal(.sessionUnlock, at: 20)
        let changed = script.settle(at: 21.5, key: "desk", hasLayout: true, keyChanged: true)
        XCTAssertEqual(changed, .restore(key: "desk", generation: script.generation))
        XCTAssertEqual(script.restores, ["desk"])
    }

    func testScreensWakeRestoresTheUnchangedLayout() {
        var script = Script()
        script.signal(.screensWake, at: 40)
        let decision = script.settle(at: 41.5, key: "desk", hasLayout: true, keyChanged: false)
        XCTAssertEqual(decision, .restore(key: "desk", generation: script.generation))
        XCTAssertEqual(script.restores, ["desk"])
    }

    func testEmptyDisplaysWaitThenALaterKeyRestores() {
        var script = Script()
        script.signal(.wake, at: 0)
        let waiting = script.settle(at: 1.5, key: nil, hasLayout: false, keyChanged: false)
        guard case .waitForDisplays = waiting else {
            return XCTFail("A wake with no displays should keep waiting, got \(waiting)")
        }
        XCTAssertEqual(script.restores, [])

        let restored = script.settle(at: 3, key: "desk", hasLayout: true, keyChanged: false)
        XCTAssertEqual(restored, .restore(key: "desk", generation: script.generation))
        XCTAssertEqual(script.restores, ["desk"])
    }

    func testStaleQuietGenerationDoesNotRestore() {
        var coalescer = DisplayRestoreCoalescer()
        guard case .arm(let first) = coalescer.note(.wake, at: 0) else {
            return XCTFail("Wake should arm one quiet wait")
        }
        guard case .arm(let second) = coalescer.note(.displayChange, at: 0.4) else {
            return XCTFail("A display change should restart the same wait")
        }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            coalescer.evaluate(first, probe(key: "desk", keyChanged: false, now: 2)),
            .skip
        )
        XCTAssertEqual(
            coalescer.evaluate(second, probe(key: "desk", keyChanged: false, now: 2)),
            .restore(key: "desk", generation: second)
        )
    }

    func testPointerDragMatchesAPressedMouseButton() {
        XCTAssertFalse(PointerDrag.isInProgress(pressedMouseButtons: 0))
        XCTAssertTrue(PointerDrag.isInProgress(pressedMouseButtons: 1))
        XCTAssertTrue(PointerDrag.isInProgress(pressedMouseButtons: 1 << 1))
        XCTAssertGreaterThanOrEqual(DisplayRestoreTiming.debounce, 1.5)
        XCTAssertLessThanOrEqual(DisplayRestoreTiming.debounce, 2)
        XCTAssertGreaterThan(DisplayRestoreTiming.sameSetupCoalesce, DisplayRestoreTiming.debounce)
        XCTAssertEqual(DisplayRestoreTiming.wakeLayoutWindow, 90)
        XCTAssertGreaterThan(DisplayRestoreTiming.wakeLayoutWindow, DisplayRestoreTiming.debounce)
    }

    func testSubsetOfASavedSetupWaitsForTheMissingDisplay() {
        for signal: DisplayRestoreCoalescer.Signal in [.wake, .screensWake, .sessionUnlock] {
            var script = Script()
            script.signal(signal, at: 0)
            let waiting = script.settle(
                at: DisplayRestoreTiming.debounce,
                key: "laptop",
                hasLayout: true,
                keyChanged: true,
                currentTokens: ["built-in"],
                preWakeTokens: ["built-in", "lu28r55"],
                preWakeHasSavedLayout: true
            )
            guard case .waitForDisplays = waiting else {
                return XCTFail("\(signal) should wait for the missing display, got \(waiting)")
            }
            XCTAssertEqual(script.restores, [])
            XCTAssertEqual(script.coalescer.lastDecisionReason, .waitingForMissingDisplay)
        }
    }

    func testMissingDisplayReturnsInsideTheWakeWindowAndRestoresOnce() {
        var script = Script()
        script.signal(.screensWake, at: 0)
        let waiting = script.settle(
            at: 1.5,
            key: "laptop",
            hasLayout: true,
            keyChanged: true,
            currentTokens: ["built-in"],
            preWakeTokens: ["built-in", "lu28r55"],
            preWakeHasSavedLayout: true
        )
        guard case .waitForDisplays = waiting else {
            return XCTFail("A subset of the saved setup should wait, got \(waiting)")
        }

        // A display-change signal inside the wake window must not give up on the missing screen.
        script.signal(.displayChange, at: 10)
        let stillWaiting = script.settle(
            at: 10 + DisplayRestoreTiming.debounce,
            key: "laptop",
            hasLayout: true,
            keyChanged: true,
            currentTokens: ["built-in"],
            preWakeTokens: ["built-in", "lu28r55"],
            preWakeHasSavedLayout: true
        )
        guard case .waitForDisplays = stillWaiting else {
            return XCTFail("A display change inside the wake window should keep waiting, got \(stillWaiting)")
        }
        XCTAssertEqual(script.restores, [])

        script.signal(.displayChange, at: 67)
        let restored = script.settle(
            at: 67 + DisplayRestoreTiming.debounce,
            key: "desk",
            hasLayout: true,
            keyChanged: false,
            currentTokens: ["built-in", "lu28r55"],
            preWakeTokens: ["built-in", "lu28r55"],
            preWakeHasSavedLayout: true
        )
        XCTAssertEqual(restored, .restore(key: "desk", generation: script.generation))
        XCTAssertEqual(script.restores, ["desk"])
        XCTAssertEqual(script.coalescer.lastDecisionReason, .wakeRestore)

        let again = script.coalescer.evaluate(
            script.generation,
            script.probe(
                key: "desk",
                hasLayout: true,
                autoRestore: true,
                drag: false,
                keyChanged: false,
                now: 70,
                currentTokens: ["built-in", "lu28r55"],
                preWakeTokens: ["built-in", "lu28r55"],
                preWakeHasSavedLayout: true
            )
        )
        XCTAssertEqual(again, .skip)
        XCTAssertEqual(script.restores, ["desk"])
    }

    func testSubsetWaitTimesOutToTheSubsetLayout() {
        var script = Script()
        script.signal(.wake, at: 0)
        let waiting = script.settle(
            at: DisplayRestoreTiming.debounce,
            key: "laptop",
            hasLayout: true,
            keyChanged: true,
            currentTokens: ["built-in"],
            preWakeTokens: ["built-in", "lu28r55"],
            preWakeHasSavedLayout: true
        )
        guard case .waitForDisplays = waiting else {
            return XCTFail("The subset should wait inside the wake window, got \(waiting)")
        }
        XCTAssertEqual(script.restores, [])

        let fallback = script.settle(
            at: DisplayRestoreTiming.wakeLayoutWindow + DisplayRestoreTiming.debounce,
            key: "laptop",
            hasLayout: true,
            keyChanged: true,
            currentTokens: ["built-in"],
            preWakeTokens: ["built-in", "lu28r55"],
            preWakeHasSavedLayout: true
        )
        XCTAssertEqual(fallback, .restore(key: "laptop", generation: script.generation))
        XCTAssertEqual(script.restores, ["laptop"])
        XCTAssertEqual(script.coalescer.lastDecisionReason, .subsetTimedOut)
    }

    func testDisplayChangeThatIsNotAWakeSubsetRestoresImmediately() {
        var script = Script()
        script.signal(.displayChange, at: 0)
        let decision = script.settle(
            at: DisplayRestoreTiming.debounce,
            key: "laptop",
            hasLayout: true,
            keyChanged: true,
            currentTokens: ["built-in"],
            preWakeTokens: ["built-in", "lu28r55"],
            preWakeHasSavedLayout: true
        )
        XCTAssertEqual(decision, .restore(key: "laptop", generation: script.generation))
        XCTAssertEqual(script.restores, ["laptop"])
        XCTAssertEqual(script.coalescer.lastDecisionReason, .keyChanged)
    }

    private func probe(
        key: String?,
        hasLayout: Bool = true,
        autoRestore: Bool = true,
        drag: Bool = false,
        keyChanged: Bool,
        now: TimeInterval,
        currentTokens: [String] = [],
        preWakeTokens: [String] = [],
        preWakeHasSavedLayout: Bool = false
    ) -> DisplayRestoreCoalescer.Probe {
        DisplayRestoreCoalescer.Probe(
            autoRestore: autoRestore,
            displayKey: key,
            hasSavedLayout: hasLayout,
            dragInProgress: drag,
            keyChanged: keyChanged,
            now: now,
            currentDisplayTokens: currentTokens,
            preWakeDisplayTokens: preWakeTokens,
            preWakeHasSavedLayout: preWakeHasSavedLayout
        )
    }

    private struct Script {
        var coalescer = DisplayRestoreCoalescer()
        var generation = 0
        var deadline: TimeInterval?
        var restores: [String] = []

        mutating func signal(_ signal: DisplayRestoreCoalescer.Signal, at time: TimeInterval) {
            switch coalescer.note(signal, at: time) {
            case .arm(let generation):
                self.generation = generation
                deadline = time + DisplayRestoreTiming.debounce
            case .coalesced:
                break
            }
        }

        mutating func settle(
            at time: TimeInterval,
            key: String?,
            hasLayout: Bool,
            autoRestore: Bool = true,
            drag: Bool = false,
            keyChanged: Bool,
            currentTokens: [String] = [],
            preWakeTokens: [String] = [],
            preWakeHasSavedLayout: Bool = false
        ) -> DisplayRestoreCoalescer.Decision {
            guard let quietDeadline = deadline, time + 0.0001 >= quietDeadline else { return .skip }
            let decision = coalescer.evaluate(generation, probe(
                key: key,
                hasLayout: hasLayout,
                autoRestore: autoRestore,
                drag: drag,
                keyChanged: keyChanged,
                now: time,
                currentTokens: currentTokens,
                preWakeTokens: preWakeTokens,
                preWakeHasSavedLayout: preWakeHasSavedLayout
            ))
            switch decision {
            case .restore(let restoredKey, let generation):
                restores.append(restoredKey)
                self.generation = generation
                armFollowUp(at: time)
            case .waitForDisplays(let generation):
                self.generation = generation
                deadline = time + DisplayRestoreTiming.debounce
            case .deferUntilDragEnds(let generation):
                self.generation = generation
                deadline = nil
            case .skip:
                deadline = nil
            }
            return decision
        }

        func probe(
            key: String?,
            hasLayout: Bool,
            autoRestore: Bool,
            drag: Bool,
            keyChanged: Bool,
            now: TimeInterval,
            currentTokens: [String] = [],
            preWakeTokens: [String] = [],
            preWakeHasSavedLayout: Bool = false
        ) -> DisplayRestoreCoalescer.Probe {
            DisplayRestoreCoalescer.Probe(
                autoRestore: autoRestore,
                displayKey: key,
                hasSavedLayout: hasLayout,
                dragInProgress: drag,
                keyChanged: keyChanged,
                now: now,
                currentDisplayTokens: currentTokens,
                preWakeDisplayTokens: preWakeTokens,
                preWakeHasSavedLayout: preWakeHasSavedLayout
            )
        }

        private mutating func armFollowUp(at time: TimeInterval) {
            switch coalescer.restoreFinished() {
            case .arm(let generation):
                self.generation = generation
                deadline = time + DisplayRestoreTiming.debounce
            case .idle:
                deadline = nil
            }
        }
    }
}
