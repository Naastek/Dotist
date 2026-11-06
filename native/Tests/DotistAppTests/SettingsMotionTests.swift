import AppKit
import Combine
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class SettingsMotionTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    /// A cancellation-insensitive suspended clock proves generation checks, not
    /// merely Task.sleep's cooperative cancellation, prevent stale feedback.
    private final class Sleeper {
        struct Wait {
            let continuation: CheckedContinuation<Void, Never>
            let returned: XCTestExpectation
        }
        var waits: [Wait] = []
        private var next: XCTestExpectation?
        func expectNextWait() -> XCTestExpectation {
            let expectation = XCTestExpectation(description: "Feedback timer suspended")
            next = expectation
            return expectation
        }
        func wait(_ duration: Duration) async {
            let returned = XCTestExpectation(description: "Suspended timer returned")
            await withCheckedContinuation { continuation in
                waits.append(Wait(continuation: continuation, returned: returned))
                next?.fulfill(); next = nil
            }
            returned.fulfill()
        }
        func releaseFirst() -> [XCTestExpectation] {
            guard !waits.isEmpty else { XCTFail("No suspended timer"); return [] }
            let first = waits.removeFirst(); first.continuation.resume()
            return [first.returned]
        }
    }
    func testSearchWaitsForActualTargetLayoutAndReduceMotionKeepsResult() async {
        let sleeper = Sleeper()
        let feedback = SettingsSearchFeedback(sleep: { await sleeper.wait($0) })
        feedback.motion = SettingsMotion(reduceMotion: true)
        var located: [String] = []
        let sleeping = sleeper.expectNextWait()
        feedback.select("appearance.字体")
        feedback.layoutReady(["general.语言"]) { _, _ in XCTFail("Wrong module is not ready") }
        XCTAssertNil(feedback.emphasized)
        feedback.layoutReady(["appearance.字体"]) { target, animation in
            XCTAssertNil(animation); located.append(target)
        }
        feedback.layoutReady(["appearance.字体"]) { _, _ in XCTFail("Must not scroll twice") }
        XCTAssertEqual(located, ["appearance.字体"])
        XCTAssertEqual(feedback.emphasized, "appearance.字体")
        await fulfillment(of: [sleeping], timeout: 2)
        let cleared = expectation(description: "Feedback emphasis cleared")
        let observation = feedback.$emphasized.dropFirst().filter { $0 == nil }
            .receive(on: DispatchQueue.main)
            .sink { _ in cleared.fulfill() }
        await fulfillment(of: sleeper.releaseFirst() + [cleared], timeout: 2)
        XCTAssertNil(feedback.emphasized)
        withExtendedLifetime(observation) {}
    }
    func testRapidSearchAndCancellationCannotResurrectOrEraseNewFeedback() async {
        for reason in ["query edit", "clear", "navigation", "close"] {
            let sleeper = Sleeper()
            let feedback = SettingsSearchFeedback(sleep: { await sleeper.wait($0) })
            let oldSleeping = sleeper.expectNextWait()
            feedback.select("old")
            feedback.layoutReady(["old"]) { _, animation in XCTAssertNotNil(animation) }
            await fulfillment(of: [oldSleeping], timeout: 2)
            feedback.cancel()
            feedback.layoutReady(["old"]) { _, _ in XCTFail(reason) }
            XCTAssertNil(feedback.request); XCTAssertNil(feedback.emphasized)
            let newSleeping = sleeper.expectNextWait()
            feedback.select("new")
            feedback.layoutReady(["new"]) { _, _ in }
            await fulfillment(of: [newSleeping], timeout: 2)
            await fulfillment(of: sleeper.releaseFirst(), timeout: 2)
            XCTAssertEqual(feedback.emphasized, "new", reason)
            feedback.cancel()
            await fulfillment(of: sleeper.releaseFirst(), timeout: 2)
            XCTAssertNil(feedback.emphasized)
        }
    }
    func testWindowCloseCancelsOnlyItsOwnHost() {
        _ = NSApplication.shared
        let feedback = SettingsSearchFeedback()
        feedback.select("target")
        let view = SettingsWindowLifetime.LifetimeView { feedback.cancel() }
        let own = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: own.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        own.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        own.contentView = view
        other.close()
        XCTAssertNotNil(feedback.request)
        own.close()
        XCTAssertNil(feedback.request)
    }
    func testPreviewUsesLiveTracksAndStopsOnCompletionCancellationAndReduceMotion() {
        var now = 10.0
        let playback = SettingsPreviewPlayback(time: { now })
        var starts = 0; var stops = 0
        playback.startClock = { starts += 1 }; playback.stopClock = { stops += 1 }
        playback.play(reduceMotion: false)
        var live = SideTabEntrance()
        live.update(ids: SettingsPreviewPlayback.ids, visible: true, at: now, reduceMotion: false)
        for elapsed in [0.0, 0.045, 0.1, 0.2] {
            now = 10 + elapsed; playback.sample()
            XCTAssertEqual(playback.values, live.values(ids: SettingsPreviewPlayback.ids, at: now))
        }
        playback.stop()
        let final = playback.values
        now += 1; playback.sample()
        XCTAssertFalse(playback.isPlaying); XCTAssertEqual(playback.values, final)
        playback.play(reduceMotion: true)
        XCTAssertEqual(starts, 1); XCTAssertEqual(playback.values, [1, 1, 1])
        playback.play(reduceMotion: false)
        now += SideTabEntrance.maximumDelay + SideTabEntrance.duration + 0.001
        playback.sample()
        XCTAssertFalse(playback.isPlaying); XCTAssertEqual(playback.values, [1, 1, 1])
        XCTAssertGreaterThan(stops, starts)
    }
    func testPreviewNativeRemovalAndWindowCloseStopPlayback() async throws {
        _ = NSApplication.shared
        for removal in [true, false] {
            let playback = SettingsPreviewPlayback(time: { 10 })
            let host = NSHostingView(rootView: AnyView(SettingsSideTabPreview(language: "en", text: { $0 }, playback: playback).frame(width: 500)))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            host.layoutSubtreeIfNeeded(); await Task.yield()
            playback.play(reduceMotion: false)
            XCTAssertTrue(playback.isPlaying)
            if removal {
                host.rootView = AnyView(Text("Other module"))
                host.layoutSubtreeIfNeeded()
            } else { window.close() }
            await drainMainQueue()
            XCTAssertFalse(playback.isPlaying, removal ? "Leaving module" : "Closing retained window")
            XCTAssertEqual(playback.values, [1, 1, 1])
            window.close()
        }
    }
    func testReducedMotionDisablesEverySettingsTransition() {
        let policy = SettingsMotion(reduceMotion: true)
        XCTAssertNil(policy.hover); XCTAssertNil(policy.selection); XCTAssertNil(policy.search); XCTAssertNil(policy.toolbar)
    }

    func testHostingViewReleaseDoesNotPublishDuringGraphDestruction() async throws {
        _ = NSApplication.shared
        for playing in [false, true] {
            let playback = SettingsPreviewPlayback(time: { 10 })
            var destroying = false
            var synchronousPublications = 0
            let observation = playback.objectWillChange.sink {
                if destroying { synchronousPublications += 1 }
            }
            weak var releasedHost: NSView?
            autoreleasepool {
                var host: NSHostingView<AnyView>? = NSHostingView(rootView: AnyView(
                    SettingsSideTabPreview(language: "en", text: { $0 }, playback: playback)
                        .frame(width: 500)))
                releasedHost = host
                host!.frame.size = host!.fittingSize
                host!.layoutSubtreeIfNeeded()
                if playing { playback.play(reduceMotion: false) }
                destroying = true
                host = nil
            }
            destroying = false
            XCTAssertNil(releasedHost, "Exercise NSHostingView.deinit, including its autorelease pool")
            XCTAssertEqual(synchronousPublications, 0, "Teardown may stop resources, but cannot publish into a dying graph")
            await drainMainQueue()
            XCTAssertFalse(playback.isPlaying)
            XCTAssertEqual(playback.values, [1, 1, 1])
            withExtendedLifetime(observation) {}
        }
    }

    func testPlayingRemovalStopsLinkImmediatelyAndOldCallbacksCannotAffectRemount() async throws {
        var now = 10.0
        let playback = SettingsPreviewPlayback(time: { now })
        let fixture = NativeRenderingFixture(AnyView(SettingsSideTabPreview(language: "en", text: { $0 }, playback: playback)),
                                             size: CGSize(width: 500, height: 210))
        defer { fixture.close() }
        await drainMainQueue()
        let oldClock = try XCTUnwrap(fixture.descendants(SettingsSideTabPreview.PreviewClock.ClockView.self).first)
        playback.play(reduceMotion: false)
        let oldLink = try XCTUnwrap(oldClock.link)
        now += 0.045
        oldClock.tick(oldLink)
        XCTAssertTrue(playback.values.contains { $0 > 0 && $0 < 1 })
        var removing = true
        var publications = 0
        let observation = playback.objectWillChange.sink { if removing { publications += 1 } }
        fixture.host.rootView = AnyView(Text("Other module"))
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertNil(oldClock.link, "Resource cleanup cannot wait for the deferred publication")
        let stopped = playback.values
        now += 0.1
        oldClock.tick(oldLink)
        playback.sample() // Even a previously queued sampler must be inert.
        XCTAssertEqual(playback.values, stopped)
        XCTAssertEqual(publications, 0)
        removing = false

        fixture.host.rootView = AnyView(SettingsSideTabPreview(language: "en", text: { $0 }, playback: playback))
        fixture.host.layoutSubtreeIfNeeded()
        let newClock = try XCTUnwrap(fixture.descendants(SettingsSideTabPreview.PreviewClock.ClockView.self).first)
        XCTAssertFalse(oldClock === newClock)
        playback.play(reduceMotion: false)
        let restarted = playback.values
        // A late dismantle of the old representable must not detach the new clock.
        SettingsSideTabPreview.PreviewClock.dismantleNSView(oldClock, coordinator: ())
        oldClock.tick(oldLink)
        await drainMainQueue()
        XCTAssertTrue(playback.isPlaying, "An old deferred reset cannot erase new playback")
        XCTAssertEqual(playback.values, restarted)
        XCTAssertNotNil(newClock.link)
        playback.play(reduceMotion: true)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.values, [1, 1, 1])
        XCTAssertNil(newClock.link)
        withExtendedLifetime(observation) {}
    }
}
