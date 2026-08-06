defmodule SpaceTraders.Agent.OperatorNotifier do
  import Swoosh.Email

  alias SpaceTraders.Mailer
  alias SpaceTraders.Agent.Operator

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"SpaceTraders", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a operator email.
  """
  def deliver_update_email_instructions(operator, url) do
    deliver(operator.email, "Update email instructions", """

    ==============================

    Hi #{operator.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(operator, url) do
    case operator do
      %Operator{confirmed_at: nil} -> deliver_confirmation_instructions(operator, url)
      _ -> deliver_magic_link_instructions(operator, url)
    end
  end

  defp deliver_magic_link_instructions(operator, url) do
    deliver(operator.email, "Log in instructions", """

    ==============================

    Hi #{operator.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(operator, url) do
    deliver(operator.email, "Confirmation instructions", """

    ==============================

    Hi #{operator.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
