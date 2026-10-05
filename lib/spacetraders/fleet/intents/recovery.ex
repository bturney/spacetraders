defmodule SpaceTraders.Fleet.Intents.Recovery do
  @moduledoc """
  The one per-kind description of how a recorded Ship action is recovered.

  Ship Execution judges each selected action's effect from fresh bound
  evidence; this description declares what that judgement needs beyond the
  acting Ship's retained source, and the shared root progression reads it for
  every ledger state. Admission reads which selected-action keys only reference
  replaceable preflight evidence. Effect predicates stay with their capability.
  """

  @enforce_keys [:kind]
  defstruct kind: nil,
            cargo: false,
            credits: nil,
            attribution: nil,
            absence: :provable,
            evidence_references: []

  @typedoc """
  * `cargo` - the action changes Cargo, so its selection blocks new Cargo work.
  * `credits` - `{accepted, absent}` Agent-credit rules its proof must satisfy:
    `:any` (credits accompany the proof), `:unchanged`, `:spent` or `:earned`
    relative to the selection's `credits_before`.
  * `attribution` - what attributes an observed effect to an unconfirmed send:
    `nil` (the effect itself), `:sent` (a dispatch marker) or `:cooldown` (a
    post-dispatch Ship cooldown).
  * `absence` - `:unprovable` when an unchanged Ship cannot prove the action
    never happened (resource yields and lost Survey/scan responses), so only
    owner-proven ledger absence may authorize its retry.
  * `evidence_references` - selected-action keys naming replaceable preflight
    observations; they do not change the request a retry repeats.
  """
  @type t :: %__MODULE__{}

  @kinds %{
    "navigate" => [],
    "warp" => [],
    "orbit" => [],
    "dock" => [],
    "set_flight_mode" => [],
    "chart" => [],
    "refuel" => [credits: {:any, :any}],
    "jump" => [credits: {:any, :unchanged}],
    "install_module" => [credits: {:any, :any}],
    "remove_module" => [credits: {:any, :any}],
    "buy" => [cargo: true, credits: {:spent, :unchanged}],
    "sell" => [cargo: true, credits: {:earned, :unchanged}],
    "deliver" => [cargo: true],
    "transfer" => [
      cargo: true,
      evidence_references: ~w(source_observation_id target_observation_id)
    ],
    "extract" => [cargo: true, attribution: :cooldown, absence: :unprovable],
    "siphon" => [cargo: true, attribution: :cooldown, absence: :unprovable],
    "refine" => [cargo: true, attribution: :cooldown, absence: :unprovable],
    "survey" => [cargo: true, attribution: :cooldown, absence: :unprovable],
    "jettison" => [cargo: true, attribution: :sent, absence: :unprovable],
    "scan_waypoints" => [attribution: :cooldown, absence: :unprovable]
  }

  @doc "Describes one selected-action kind; an unknown kind has no extra requirements."
  @spec describe(String.t() | map() | nil) :: t()
  def describe(%{"kind" => kind}), do: describe(kind)

  def describe(kind) when is_binary(kind),
    do: struct!(__MODULE__, [kind: kind] ++ Map.get(@kinds, kind, []))

  def describe(_action), do: %__MODULE__{kind: nil}

  @doc "Drops replaceable preflight evidence references from a selected action."
  @spec request_identity(map()) :: map()
  def request_identity(action) when is_map(action),
    do: Map.drop(action, describe(action).evidence_references)

  @doc "Checks an Agent-credit observation against the kind's rule for a verdict."
  def credits_consistent?(%__MODULE__{credits: nil}, _outcome, _action, _credits), do: true

  def credits_consistent?(%__MODULE__{credits: {accepted, absent}}, outcome, action, credits)
      when is_integer(credits) and credits >= 0 do
    rule = if outcome == :absent, do: absent, else: accepted
    credit_rule?(rule, action["credits_before"], credits, action["listing_price"])
  end

  def credits_consistent?(_recovery, _outcome, _action, _credits), do: false

  defp credit_rule?(:any, _before, _after, _price), do: true
  defp credit_rule?(_rule, before, _after, _price) when not is_integer(before), do: false
  defp credit_rule?(:unchanged, before, after_credits, _price), do: after_credits == before

  defp credit_rule?(:spent, before, after_credits, price),
    do: after_credits < before or (price == 0 and after_credits == before)

  defp credit_rule?(:earned, before, after_credits, price),
    do: after_credits > before or (price == 0 and after_credits == before)
end
