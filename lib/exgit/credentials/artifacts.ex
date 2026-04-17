defmodule Exgit.Credentials.Artifacts do
  @moduledoc false

  @spec auth(String.t()) :: Exgit.Transport.HTTP.auth()
  def auth(token), do: {:bearer, token}
end
