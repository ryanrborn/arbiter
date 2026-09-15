defmodule Arbiter.Sessions.Naming do
  @moduledoc """
  The one place that knows how a session id maps to its OS-level handles
  (bd-bpt0ag, phase 1 of `docs/browser-hosted-coordinator-sessions.md`).

  Everything about a live session is **derivable from its id**:

      id           = "0197…"
      scope unit   = "arb-session-0197….scope"
      tmux socket  = "$XDG_RUNTIME_DIR/arbiter/session-0197….sock"
      tmux session = "coord"

  That is deliberate, and it is what makes restart survival cheap (§4.3):
  Arbiter holds no handle to the PTY, so after a restart it re-derives the
  unit name and socket path from the row rather than remembering a pid, a
  port, or a file descriptor. It is also what lets the adoption sweep run the
  mapping *backwards* — `session_id_from_unit/1` turns a unit name that
  `systemctl --user list-units 'arb-session-*'` printed back into the id to
  look up.

  The `.scope` suffix is carried in `scope_unit/1` because that is how
  `systemctl` prints it, and unit-name matching in the sweep is a string
  compare. `unit_arg/1` drops it again for `systemd-run --unit=`, matching the
  RFC §4.3 command shape literally.
  """

  @unit_prefix "arb-session-"
  @socket_prefix "session-"
  @tmux_session "coord"

  @doc "The `--unit=` argument for `systemd-run`, without the `.scope` suffix."
  @spec unit_arg(String.t()) :: String.t()
  def unit_arg(id) when is_binary(id), do: @unit_prefix <> id

  @doc "The full systemd unit name, as `systemctl` prints it."
  @spec scope_unit(String.t()) :: String.t()
  def scope_unit(id) when is_binary(id), do: unit_arg(id) <> ".scope"

  @doc "The glob `systemctl --user list-units` is given to enumerate session scopes."
  @spec unit_glob() :: String.t()
  def unit_glob, do: @unit_prefix <> "*"

  @doc """
  The session id inside a unit name, or `nil` when the name is not one of ours.

  Accepts the name with or without the `.scope` suffix, because `systemctl`
  output has been seen with both a bare name and a decorated one.
  """
  @spec session_id_from_unit(String.t()) :: String.t() | nil
  def session_id_from_unit(unit) when is_binary(unit) do
    with @unit_prefix <> rest <- String.trim(unit),
         id when id != "" <- String.trim_trailing(rest, ".scope") do
      id
    else
      _ -> nil
    end
  end

  @doc """
  Absolute path of the session's tmux socket.

  Lives under `$XDG_RUNTIME_DIR/arbiter/` — a tmpfs that is wiped on logout,
  which is the correct lifetime for a socket whose session cannot outlive the
  user manager anyway.
  """
  @spec socket_path(String.t()) :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def socket_path(id) when is_binary(id) do
    case socket_dir() do
      {:ok, dir} -> {:ok, Path.join(dir, @socket_prefix <> id <> ".sock")}
      error -> error
    end
  end

  @doc "The directory holding every session socket."
  @spec socket_dir() :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def socket_dir do
    case runtime_dir() do
      nil -> {:error, :no_runtime_dir}
      dir -> {:ok, Path.join(dir, "arbiter")}
    end
  end

  @doc "Glob matching every session socket on this host."
  @spec socket_glob() :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def socket_glob do
    case socket_dir() do
      {:ok, dir} -> {:ok, Path.join(dir, @socket_prefix <> "*.sock")}
      error -> error
    end
  end

  @doc "The session id a socket path belongs to, or `nil`."
  @spec session_id_from_socket(String.t()) :: String.t() | nil
  def session_id_from_socket(path) when is_binary(path) do
    with @socket_prefix <> rest <- Path.basename(path),
         true <- String.ends_with?(rest, ".sock"),
         id when id != "" <- String.trim_trailing(rest, ".sock") do
      id
    else
      _ -> nil
    end
  end

  @doc """
  The tmux session name inside the socket — a constant.

  One tmux session per socket, always called `coord`, so `§4.7`'s documented
  fallback (`tmux -S … attach -t coord`) is a fixed string an operator can
  type from memory when Arbiter is down.
  """
  @spec tmux_session() :: String.t()
  def tmux_session, do: @tmux_session

  # `XDG_RUNTIME_DIR` is set for every systemd user session, which is the only
  # environment a session can launch in (`systemd-run --user` needs the user
  # manager anyway). Config override exists so a test can point the socket dir
  # at a tmp_dir without exporting a var into the whole VM.
  defp runtime_dir do
    Application.get_env(:arbiter, :sessions_runtime_dir) || System.get_env("XDG_RUNTIME_DIR")
  end
end
