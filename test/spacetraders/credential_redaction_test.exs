defmodule SpaceTraders.CredentialRedactionTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.Agent.{Agent, Operator}

  test "AccountToken and AgentToken fields are redacted when records are inspected" do
    account_token = "ACCOUNT_TOKEN_SECRET"
    agent_token = "AGENT_TOKEN_SECRET"

    operator_inspection = inspect(%Operator{account_token: account_token})
    agent_inspection = inspect(%Agent{agent_token: agent_token})

    refute operator_inspection =~ account_token
    refute agent_inspection =~ agent_token
  end

  test "JSON logging only admits non-secret correlation metadata" do
    {_formatter, options} =
      Application.fetch_env!(:logger, :default_handler)
      |> Keyword.fetch!(:formatter)

    allowed_metadata = Keyword.fetch!(options, :metadata)

    assert :request_id in allowed_metadata
    assert :intent_id in allowed_metadata
    assert :correlation_id in allowed_metadata
    assert :requested_at in allowed_metadata
    assert :request_time in allowed_metadata
    refute :account_token in allowed_metadata
    refute :agent_token in allowed_metadata
    refute :token in allowed_metadata
    refute :password in allowed_metadata
  end
end
