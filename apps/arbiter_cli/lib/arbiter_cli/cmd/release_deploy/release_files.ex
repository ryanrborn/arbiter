defmodule ArbiterCli.Cmd.ReleaseDeploy.ReleaseFiles do
  @moduledoc """
  Filesystem side of `arb server deploy`: unpacking the release tarball,
  running migrations, the atomic `current` symlink swap, and pruning old
  releases under the deploy data home.
  """

  alias ArbiterCli.Cmd.Start
  alias ArbiterCli.Output

  # How many *prior* releases to keep around for rollback after a successful
  # deploy. The current release is always retained on top of these.
  @retain_prior 3

  @spec data_home() :: String.t()
  def data_home do
    case System.get_env("ARB_DATA_HOME") do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> Path.join(System.user_home!(), ".arbiter")
    end
  end

  @spec releases_dir() :: String.t()
  def releases_dir, do: Path.join(data_home(), "releases")
  @spec current_link() :: String.t()
  def current_link, do: Path.join(data_home(), "current")

  # `Restart.perform/2` only uses `root` for its non-systemd `mix phx.server`
  # fallback; in the release world the systemd unit owns the process, so the
  # current symlink dir is a fine, always-present value to pass.
  @spec restart_root(String.t()) :: String.t()
  def restart_root(current_link), do: current_link

  # Unpack the OTP-release tarball into `target_dir`. The tarball has a single
  # top-level `arbiter/` directory (it's built with `tar -C _build/prod/rel
  # arbiter`); we strip that leading component so `bin/arbiter` lands directly
  # under `target_dir`.
  @spec unpack!(binary(), String.t()) :: :ok
  def unpack!(tarball, target_dir) do
    # Start from a clean directory so a retried deploy of the same tag can't
    # mix old and new files.
    _ = File.rm_rf(target_dir)
    File.mkdir_p!(target_dir)

    staging = target_dir <> ".unpack"
    _ = File.rm_rf(staging)
    File.mkdir_p!(staging)

    Start.log_text("Unpacking release to #{target_dir}…")

    case :erl_tar.extract({:binary, tarball}, [:compressed, {:cwd, to_charlist(staging)}]) do
      :ok ->
        promote_unpacked!(staging, target_dir)
        _ = File.rm_rf(staging)
        :ok

      {:error, reason} ->
        _ = File.rm_rf(staging)
        _ = File.rm_rf(target_dir)
        Output.die("failed to unpack the release tarball", inspect(reason))
    end
  end

  # Move the contents of the tarball's top-level dir up into `target_dir`. If
  # the archive has the expected single `arbiter/` root we strip it; otherwise
  # we keep whatever layout it shipped (defensive — still produces a usable
  # release dir for non-standard archives).
  defp promote_unpacked!(staging, target_dir) do
    case File.ls!(staging) do
      [single] ->
        single_path = Path.join(staging, single)

        if File.dir?(single_path) do
          Enum.each(File.ls!(single_path), fn entry ->
            File.rename!(Path.join(single_path, entry), Path.join(target_dir, entry))
          end)
        else
          File.rename!(single_path, Path.join(target_dir, single))
        end

      entries ->
        Enum.each(entries, fn entry ->
          File.rename!(Path.join(staging, entry), Path.join(target_dir, entry))
        end)
    end
  end

  @spec run_migrations!(String.t()) :: :ok
  def run_migrations!(target_dir) do
    bin = Path.join(target_dir, "bin/arbiter")
    Start.log_text("Running migrations (bin/arbiter eval Arbiter.Release.migrate)…")

    case Start.run_cmd(bin, ["eval", "Arbiter.Release.migrate"], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        # Migration failed *before* we swapped the symlink — the live server is
        # untouched, so just abort.
        _ = File.rm_rf(target_dir)

        Output.die(
          "database migration failed (exit #{code})",
          "The live release was not changed. Output:\n" <> String.trim_trailing(out)
        )
    end
  rescue
    e in ErlangError ->
      _ = File.rm_rf(target_dir)

      Output.die(
        "could not run #{Path.join(target_dir, "bin/arbiter")}: #{inspect(e.original)}",
        "Is the unpacked release executable on this platform?"
      )
  end

  # Atomically point `link_path` at `target` by creating a temp symlink and
  # rename(2)-ing it over the existing one. rename is atomic on POSIX, so a
  # concurrent reader sees either the old target or the new one, never nothing.
  @spec atomic_symlink_swap!(String.t(), String.t()) :: :ok
  def atomic_symlink_swap!(link_path, target) do
    File.mkdir_p!(Path.dirname(link_path))
    tmp = link_path <> ".new"
    _ = File.rm(tmp)

    with :ok <- File.ln_s(target, tmp),
         :ok <- File.rename(tmp, link_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        Output.die("failed to swap the current-release symlink", inspect(reason))
    end
  end

  # The release dir `link_path` currently resolves to (absolute), or nil if the
  # link is absent (first-ever deploy).
  @spec current_target(String.t()) :: String.t() | nil
  def current_target(link_path) do
    case File.read_link(link_path) do
      {:ok, target} -> Path.expand(target, Path.dirname(link_path))
      _ -> nil
    end
  end

  @spec current_target_basename(String.t()) :: String.t() | nil
  def current_target_basename(link_path) do
    case current_target(link_path) do
      nil -> nil
      target -> Path.basename(target)
    end
  end

  @spec prior_basename(String.t() | nil) :: String.t() | nil
  def prior_basename(nil), do: nil
  def prior_basename(path), do: Path.basename(path)

  # Keep the current release plus the @retain_prior most-recent other releases
  # (by mtime); delete the rest. Returns the list of pruned tags.
  @spec prune_old_releases(String.t(), String.t(), String.t() | nil) :: [String.t()]
  def prune_old_releases(releases_dir, current_target, prior_target) do
    keep_always =
      [current_target, prior_target]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.basename/1)
      |> MapSet.new()

    all =
      releases_dir
      |> list_release_dirs()
      |> Enum.sort_by(&dir_mtime(releases_dir, &1), :desc)

    # The newest @retain_prior dirs that aren't already force-kept, plus the
    # always-keep set, form the retained set.
    extra_keep =
      all
      |> Enum.reject(&MapSet.member?(keep_always, &1))
      |> Enum.take(@retain_prior)
      |> MapSet.new()

    keep = MapSet.union(keep_always, extra_keep)

    pruned =
      all
      |> Enum.reject(&MapSet.member?(keep, &1))

    Enum.each(pruned, fn tag ->
      _ = File.rm_rf(Path.join(releases_dir, tag))
    end)

    if pruned != [], do: Start.log_text("Pruned old release(s): #{Enum.join(pruned, ", ")}")
    pruned
  end

  defp list_release_dirs(releases_dir) do
    case File.ls(releases_dir) do
      {:ok, entries} ->
        Enum.filter(entries, fn e ->
          File.dir?(Path.join(releases_dir, e)) and not String.ends_with?(e, ".unpack")
        end)

      _ ->
        []
    end
  end

  defp dir_mtime(releases_dir, tag) do
    case File.stat(Path.join(releases_dir, tag), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> 0
    end
  end
end
