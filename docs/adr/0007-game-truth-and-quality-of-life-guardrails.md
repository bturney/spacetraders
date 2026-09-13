# Game truth and quality-of-life guardrails

Reaffirmed as the gameplay authority boundary by
[ADR 0010](0010-autonomous-runtime.md).

The SpaceTraders game is authoritative for action eligibility and available choices; app code must reflect its rules rather than silently narrow or change them. Local rules are permitted only as explicit quality-of-life guardrails: they may prevent actions known to fail from fresh local state, make transient state legible, or present unavailable data, while preserving the game call as the authoritative backstop. This rejects app-owned restrictions such as limiting Shipyard Listings to the Headquarters System.
