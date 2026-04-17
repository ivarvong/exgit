defmodule Exgit.Credentials.GitHub do
  @moduledoc false

  @spec auth(String.t()) :: Exgit.Transport.HTTP.auth()
  def auth(token), do: {:basic, "x-access-token", token}
end
