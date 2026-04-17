defmodule Exgit.Credentials.BitbucketCloud do
  @moduledoc false

  @spec auth(String.t(), String.t()) :: Exgit.Transport.HTTP.auth()
  def auth(username, app_password), do: {:basic, username, app_password}
end
