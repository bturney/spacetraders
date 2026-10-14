# Game secrets live in the database, not in `.env`

Status: Multi-Operator rationale superseded by [ADR 0015](0015-single-operator-single-current-agent.md). Encrypted database credential storage remains accepted.

Game credentials are application data, not deployment config. The sole Operator's
encrypted AccountToken authorizes minting; each retained Agent's encrypted AgentToken
authorizes only its own game identity, and the application admits gameplay only for
the published current Fleet. `.env` holds deployment secrets (DB/encryption key),
never game tokens. ADR 0015 supersedes the original multi-Operator rationale without
changing credential encryption or historical AgentToken retention.
