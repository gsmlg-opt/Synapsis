// Only host construction records trust; error names and prototypes are forgeable.
const trustedToolInputErrors = new WeakSet        ();

export class ToolInputError extends Error {
           status         = 400;

  constructor(message        ) {
    super(message);
    this.name = "ToolInputError";
    trustedToolInputErrors.add(this);
  }
}

export class ToolAuthorizationError extends ToolInputError {
                    status = 403;

  constructor(message        ) {
    super(message);
    this.name = "ToolAuthorizationError";
  }
}

export function isTrustedToolInputError(error         )          {
  return typeof error === "object" && error !== null && trustedToolInputErrors.has(error);
}
