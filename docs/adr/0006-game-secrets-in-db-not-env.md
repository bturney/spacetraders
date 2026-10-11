# Game secrets live in the database, not in `.env`

Status: Multi-Operator rationale superseded by [ADR 0015](0015-single-operator-single-current-agent.md). Encrypted database credential storage remains accepted.

Operator and agent credentials are application data, not deployment config. Each operator's AccountToken (stored encrypted, used only to mint agents in-app) and each agent's AgentToken (used to authorize that agent's game actions) are stored in the DB against their owner. `.env` holds only deployment secrets (DB/encryption key, admin seed). This enables multiple operators on one deployment, each minting and playing their own agents, without exposing any game credentials as host config. AgentTokens are per-agent, so a leaked token cannot touch another agent's fleet.
