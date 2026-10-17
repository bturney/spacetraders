# Glossary Map

Two contexts. Every term lives in exactly one; retired terms stay marked where they were defined.

## Contexts

- [Game](./GLOSSARY.md): the SpaceTraders game and every Operator surface (Mission Control, Ships, Ship pages, player Grafana dashboards). Game vocabulary only.
- [Strategy engine](./docs/strategy-engine/GLOSSARY.md): the autonomous planner and executor (Fleet Strategy, Episode, Commitment, Portfolio, Revision, Intent, Endeavor, Jobs). Used only in engine Grafana dashboards, logs and engine pages.

## Relationships

- **Engine → Game**: engine terms are built from Game terms (Ship, Cargo, Net Earnings, Neutral Wait). A few Game definitions (Neutral Wait, Net Earnings) cite engine terms as their source of truth; Operator surfaces still show only the Game term.
- **Operator surfaces**: show Game terms only. Plan Health is a Game term; its status and health wording is copy, not glossary terms.
- **Naming a concept**: grep both glossaries; add a term to the context whose surfaces use it.
