import Testing
@testable import Strobe

/// The claims readers and the Settings sample make on the app's one audio
/// session, which decide when it's deactivated. `#expect` can't call the
/// mutating methods itself, so each result is taken first.
struct ReadAloudAudioSessionTests {
    private typealias Claims = ReadAloudAudioSession.Claims

    /// Claims in which each of `clients` has activated the session.
    private func active(_ clients: Int...) -> Claims {
        var claims = Claims()
        for client in clients {
            let request = claims.activate(client)
            claims.activationSucceeded(request, client: client)
        }
        return claims
    }

    @Test func sessionStaysActiveUntilTheLastClientLetsGo() {
        var claims = active(1, 2)
        #expect(claims.clients == [1, 2])
        // The sample stopping leaves the reader playing.
        let sampleWasLast = claims.deactivate(2)
        #expect(!sampleWasLast)
        #expect(claims.clients == [1])
        let readerWasLast = claims.deactivate(1)
        #expect(readerWasLast)
        #expect(claims.clients.isEmpty)
    }

    @Test func deactivatingTwiceDeactivatesOnce() {
        var claims = active(1)
        let first = claims.deactivate(1)
        let second = claims.deactivate(1)
        // Nor does one that never activated.
        let never = claims.deactivate(2)
        #expect(first)
        #expect(!second)
        #expect(!never)
    }

    @Test func claimStartsWithTheActivation() {
        var claims = Claims()
        _ = claims.activate(1)
        #expect(claims.clients == [1])
        // Deactivating before activating finishes still goes through.
        let deactivates = claims.deactivate(1)
        #expect(deactivates)
    }

    /// A deactivation and an activation can be asked for while an earlier
    /// activation is under way; its failure mustn't undo the later claim.
    @Test func staleFailureLeavesTheNewerClaim() {
        var claims = Claims()
        let first = claims.activate(1)
        let deactivates = claims.deactivate(1)
        #expect(deactivates)
        let second = claims.activate(1)
        let staleFailureDeactivates = claims.activationFailed(first, client: 1)
        #expect(!staleFailureDeactivates)
        #expect(claims.clients == [1])
        claims.activationSucceeded(second, client: 1)
        let lastDeactivates = claims.deactivate(1)
        #expect(lastDeactivates)
    }

    @Test func staleSuccessDoesntClaimAgain() {
        var claims = Claims()
        let request = claims.activate(1)
        let deactivates = claims.deactivate(1)
        #expect(deactivates)
        claims.activationSucceeded(request, client: 1)
        #expect(claims.clients.isEmpty)
    }

    @Test func failedActivationHoldsNothing() {
        var claims = Claims()
        let request = claims.activate(1)
        let failureDeactivates = claims.activationFailed(request, client: 1)
        #expect(failureDeactivates)
        #expect(claims.clients.isEmpty)
        let deactivates = claims.deactivate(1)
        #expect(!deactivates)
    }

    @Test func failedActivationLeavesOtherClaims() {
        var claims = active(2)
        let request = claims.activate(1)
        let failureDeactivates = claims.activationFailed(request, client: 1)
        #expect(!failureDeactivates)
        #expect(claims.clients == [2])
        let deactivates = claims.deactivate(2)
        #expect(deactivates)
    }

    /// An interruption deactivates the session for every client, so none
    /// deactivates it again.
    @Test func interruptionGivesUpEveryClaim() {
        var claims = active(1, 2)
        claims.sessionWasDeactivated()
        #expect(claims.clients.isEmpty)
        let first = claims.deactivate(1)
        let second = claims.deactivate(2)
        #expect(!first)
        #expect(!second)
    }

    /// An activation that finishes after an interruption leaves the session
    /// active, so its client claims it again.
    @Test func activationFinishingAfterAnInterruptionClaimsAgain() {
        var claims = Claims()
        let request = claims.activate(1)
        claims.sessionWasDeactivated()
        claims.activationSucceeded(request, client: 1)
        #expect(claims.clients == [1])
        let deactivates = claims.deactivate(1)
        #expect(deactivates)
    }
}
