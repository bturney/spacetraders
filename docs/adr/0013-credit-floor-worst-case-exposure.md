# Credit floor is enforced against calibrated worst-case exposure

SpaceTraders requests carry quantities, not price caps, and the game charges whatever the price is when a request arrives. The credit floor nonetheless stays a Hard Constraint. Every credit-bearing action is admitted only when the realized Agent balance, after subtracting the worst-case cost of every admitted, in-flight, or Bounded Unknown credit-bearing attempt across the Fleet, stays at or above the floor. The worst-case cost is a fresh quote × (1 + a calibrated margin) × units. We chose this over treating the floor as a Preference or a best-effort check because #505 showed a quantity-only purchase repricing from 800 to 1,100 credits and leaving the Agent below the floor. A Hard Constraint that ignores repricing and concurrency is a guarantee the system cannot honour (#502 C01, C05).

## Rules

- **Fresh quote or no spend.** Every credit-bearing action needs a quote within its freshness window at the final authority check before send. Refuel sends explicit `units`. An action without a computable bound is not admitted. A Ship that would be stranded without fuel is a safety condition for Attention, not a silent floor breach.
- **Units are capped by the bound.** Units ≤ the lowest of `tradeVolume`, free Cargo, and what the floor headroom affords at the worst-case price.
- **Realized balance only.** Expected sale proceeds and Contract payouts never offset exposure until they land.
- **One calculation, two checkpoints.** Fleet Allocation holds the Fleet-wide credit Reservations at selection. The final authority check before send revalidates them against a fresh quote using the same calculation. Fixed allowances (fuel, bounded-loss, refit, and `floor + 750` reserves) are deleted.
- **The margin is calibration, not intent.** It starts conservative (for example 25%), labelled as an initial model, and narrows only as realized-versus-quoted evidence accumulates, within a hard lower bound. It is versioned and reversible and can never edit the floor (#502 C10).
- **Breach handling.** If a realized charge still takes the balance below the floor, the breach is recorded durably and raises Degraded Attention. New credit-bearing admissions pause until the balance recovers, while non-spending work continues. The margin widens with a new version. Cargo is never sold automatically to restore the floor.
- **Revision changes.** Activating a revision revalidates all credit Reservations. Work that no longer fits is released at its next safe point. Requests already sent settle normally, and any shortfall follows the breach rule.
- **Truthful review.** The Strategy review describes the floor as protected against calibrated worst-case price movement, and says that SpaceTraders cannot cap prices and that breaches are recorded and pause spending.

## Considered Options

- **Floor as a target with bounded overshoot, or as a Preference:** rejected. It turns a Hard Constraint into a forecast.
- **Fixed allowances or a flat margin:** rejected. #502 C05 forbids constants asserted to be the worst case.
- **Buying in small lots:** rejected. It multiplies API calls and still needs a margin.
- **Exempting refuel and jump:** rejected. Stranding risk goes to the Operator as Attention instead.
- **Selling automatically on breach:** rejected. It is a new strategic act the Operator did not authorize.
