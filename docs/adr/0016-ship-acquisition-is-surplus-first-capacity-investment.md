# Ship acquisition is a surplus-first Capacity Investment allocated after Market work

A Ship purchase is a one-time capital cost whose benefit is conditional and spread over the rest of its Fleet Generation. Gate 2C (#729) values it as a Capacity Investment rather than as its own Strategic Objective. It earns the incremental progress it enables on existing objectives. It is admitted only when the latest Fleet Allocation decision left admissible work unselected purely for lack of a Ship, and it spends only credits left above the credit floor plus selected and retained Reservations. A Fleet Allocation-owned step decides it after the Market domain decision at the same boundary, adding at most one acquisition Commitment to the current portfolio through the same versioned publication. We chose this because it is the simplest design that removes the old "a portfolio exists, so no acquisition" exclusion, keeps one publication authority (#502 C02), and cannot starve productive trade. It also avoids ranking one trade trip against a whole horizon of enabled value.

## Considered Options

- **Acquisition as its own Strategic Objective (previous code):** rejected. It was gated by objective text that no preset contains, ranked by Strategic Priority order alone, and valued by engine speed.
- **One ranking of trade and acquisition in credits over the Generation Horizon:** deferred, not rejected. It lets an investment displace trade, but it needs a cross-horizon comparison we cannot yet evidence.
- **Acquisition decided inside the Market domain decision:** rejected. It would grow the Market domain into an all-capability coordinator.
- **Acquisition keeps publishing its own portfolio:** rejected. It is a second publication authority.

## Consequences

- When trade keeps the surplus tied up, acquisition waits.
- With no announced Server Reset the Generation Horizon is unknown, and no Ship is bought.
- A purchase Commitment holds a credit Reservation but no Claim. Settling it releases only that Commitment.
