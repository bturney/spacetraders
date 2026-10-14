# Game identity is established through authenticated mint/import, never fake
# credentials or a raw Agent insert. This seed is safe for empty/current history.
:ok = SpaceTraders.AgentNameBank.ensure_defaults()
