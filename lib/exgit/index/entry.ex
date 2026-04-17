defmodule Exgit.Index.Entry do
  @moduledoc false

  @enforce_keys [:name, :sha, :mode]
  defstruct [
    :name,
    :sha,
    :mode,
    :dev,
    :ino,
    :uid,
    :gid,
    stage: 0,
    size: 0,
    ctime: {0, 0},
    mtime: {0, 0},
    assume_valid: false,
    intent_to_add: false,
    skip_worktree: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          sha: binary(),
          mode: non_neg_integer(),
          stage: 0..3,
          size: non_neg_integer(),
          ctime: {non_neg_integer(), non_neg_integer()},
          mtime: {non_neg_integer(), non_neg_integer()},
          dev: non_neg_integer() | nil,
          ino: non_neg_integer() | nil,
          uid: non_neg_integer() | nil,
          gid: non_neg_integer() | nil,
          assume_valid: boolean(),
          intent_to_add: boolean(),
          skip_worktree: boolean()
        }
end
