export class SessionTranscriptProjectionUnavailableError extends Error {
    sessionId;
    reason;
    constructor(sessionId, reason = "rebuilding"){
        super(`Session transcript ${reason === "rebuilding" ? "projection is rebuilding" : "history window changed"}: ${sessionId}`), this.sessionId = sessionId, this.reason = reason;
        this.name = "SessionTranscriptProjectionUnavailableError";
    }
}
