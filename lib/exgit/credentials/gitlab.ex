defmodule Exgit.Credentials.GitLab do
  @moduledoc false

  @spec auth(String.t()) :: Exgit.Transport.HTTP.auth()
  def auth(token), do: {:basic, "oauth2", token}
end
