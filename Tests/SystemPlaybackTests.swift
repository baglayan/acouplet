#if !ACOUPLET_PUBLIC_APIS_ONLY
import XCTest
@testable import Acouplet

final class SystemPlaybackTests: XCTestCase {
    @MainActor
    func testSimulationRecordsExplicitCommandsWithoutLoadingLiveSender() {
        let playback = SystemPlayback(simulated: true)
        XCTAssertTrue(playback.isAvailable)
        XCTAssertNil(playback.lastCommand)
        XCTAssertNil(playback.error)
        for command in [SystemPlayback.Command.togglePlayPause, .next, .previous] {
            XCTAssertTrue(playback.send(command))
            XCTAssertEqual(playback.lastCommand, command)
            XCTAssertNil(playback.error)
        }
    }

    @MainActor
    func testCommandIsSentOnlyOnExplicitRequestAndFailureIsReported() {
        var commands: [SystemPlayback.Command] = []
        var reply: SystemPlayback.Reply?
        let playback = SystemPlayback(sender: { command, completion in
            commands.append(command)
            reply = completion
            return true
        })
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(playback.send(.togglePlayPause))
        XCTAssertEqual(commands, [.togglePlayPause])
        XCTAssertNil(playback.error)
        reply?([2])
        XCTAssertNotNil(playback.error)
    }

    @MainActor
    func testEarlierReplyCannotReplaceLatestCommandResult() {
        var replies: [SystemPlayback.Reply] = []
        let playback = SystemPlayback(sender: { _, reply in
            replies.append(reply)
            return true
        })
        playback.send(.next)
        playback.send(.previous)
        replies[0]([2])
        XCTAssertNil(playback.error)
        replies[1](nil)
        XCTAssertNotNil(playback.error)
        playback.send(.togglePlayPause)
        replies[2]([2, 0])
        XCTAssertNil(playback.error)
    }

    @MainActor
    func testUnavailableOrUnsubmittedCommandsDoNotRecordDelivery() {
        let unavailable = SystemPlayback(sender: nil)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertFalse(unavailable.send(.next))
        XCTAssertNil(unavailable.lastCommand)
        XCTAssertNotNil(unavailable.error)

        let rejected = SystemPlayback(sender: { _, _ in false })
        XCTAssertFalse(rejected.send(.previous))
        XCTAssertNil(rejected.lastCommand)
        XCTAssertNotNil(rejected.error)
    }
}
#endif
