defmodule Arbiter.Agents.Gemini.Security do
  @moduledoc """
  Translates a provider-agnostic `Arbiter.Agents.SecurityPolicy` into the
  `agy` (Antigravity) CLI's concrete permission mechanism — the agy analogue of
  `Arbiter.Agents.Claude.Security` (bd-7s29yq / T6b).

  ## Why this exists

  agy has no `--settings` flag and no config-dir env var: its permission
  posture comes from `$HOME/.gemini/antigravity-cli/settings.json` and nothing
  else. Before this module an agy worker silently inherited the *operator's*
  file — on this install `toolPermission: "always-proceed"` with no deny list
  at all, i.e. every worker ran `always-proceed` regardless of the workspace's
  `:strict`/`:auto` posture. `Arbiter.Agents.Gemini.ConfigDir` gives the spawn
  its own `HOME`; this module generates the settings document that lands in it.

  ## Mapping

  | Normalized mode | agy argv | `toolPermission` | Deny enforced? |
  |---|---|---|---|
  | `:bypass` | `--dangerously-skip-permissions` | `always-proceed`      | **yes** |
  | `:auto`   | *(none)*                         | `always-proceed`      | **yes** |
  | `:strict` | *(none)*                         | `proceed-in-sandbox`  | **yes** (unallowed ⇒ blocked) |

  Every row was confirmed live against the installed `agy` (1.2.8), with a
  throwaway `$HOME`:

    * The generated `settings.json` **is** read in place of the operator's, and
      `toolPermission` is echoed verbatim as `init.permission_mode` on the
      stream-json `init` event — which is exactly what AC1 asserts on.
    * `permissions.deny` is a **hard block in every mode**, including under
      `--dangerously-skip-permissions`: with `deny: ["command(rm)"]` a
      `rm ./inside.txt` came back
      `permission check failed for unsandboxed "rm ./inside.txt"` and the file
      survived. This is why `Arbiter.Agents.Gemini.security_enforced?/0` can
      honestly answer `true`.
    * **`toolPermission: "strict"` is a dead end for headless use (bd-25ivqe).**
      Probed directly: with `toolPermission: "strict"`, a `run_command` was
      auto-denied (`permission check failed for unsandboxed ...`) no matter
      what `permissions.allow` said — a bare `command(arb)`, a wildcard
      `command(*)`, and even the exact literal full command string all still
      came back denied. `permissions.allow` is simply never consulted under
      this value in headless/print mode; only `--dangerously-skip-permissions`
      (i.e. `always-proceed`) lets anything through. This is what made the
      original bd-25ivqe fix (allowlist-only, `toolPermission: "strict"`) look
      correct in a code review and in unit tests asserting on the *generated
      document*, yet still auto-deny every command live — see the task's
      post-merge verification failure.
    * **`toolPermission: "proceed-in-sandbox"` is the value that actually
      works headlessly.** Same settings document, only `toolPermission`
      changed: an allow-listed command (`command(arb)` → `arb --version`,
      `read_file(**)` → `view_file`) succeeded, and a command with no
      matching allow rule (`whoami`) was denied the same way `"strict"`
      denies everything. `:strict` therefore maps onto agy's
      `"proceed-in-sandbox"`, not its own `"strict"` — a confusing but
      confirmed-live naming mismatch between Arbiter's normalized mode and
      agy's own vocabulary.
    * **The `--sandbox` argv flag defeats the allowlist gate under
      `"proceed-in-sandbox"` (bd-25ivqe).** With `--sandbox` on argv, agy runs
      the command inside a real `bwrap` jail (this host has `bwrap`) and
      *auto-proceeds* there regardless of `permissions.allow` — the same
      `whoami` probe that was denied without `--sandbox` succeeded with it,
      allow rule or not. Only `permissions.deny` still gated it (confirmed:
      denying `command(whoami)` blocked it in both the sandboxed and
      unsandboxed execution paths agy tried). So `--sandbox` is now omitted
      from `:strict`'s argv entirely — the original `["--sandbox"]` mapping
      predates this finding and, combined with `"proceed-in-sandbox"`, would
      make `:strict` an allow-anything-but-explicit-denies posture instead of
      the allowlist-only one this module promises.
    * `:strict` is therefore genuinely allowlist-only **only when** the argv
      omits `--sandbox` and the settings carry `toolPermission:
      "proceed-in-sandbox"`: a `:strict` agy worker gets no shell at all
      unless the workspace policy names the commands it may run.

  ## Honesty about enforcement level

  Two things the operator might reasonably expect that agy does **not** give us,
  both probed directly:

    * `allowNonWorkspaceAccess: false` did **not** stop an out-of-worktree
      access in `always-proceed`: a `touch <outside>/marker` via `run_command`
      succeeded, and so did a `view_file` read of a file outside the workspace.
      We still emit the key (it is the documented switch and costs nothing), but
      the load-bearing out-of-worktree guard is the `write_file(...)` deny list
      below plus `:strict`'s allowlist-only shell — not this flag. Note this
      applies to `write_file` specifically: unlike `command`/`read_file`, an
      out-of-worktree `write_to_file` with *no* matching allow rule at all
      still succeeded under `"proceed-in-sandbox"` — `write_file` is
      deny-list-gated, not allowlist-gated, in every `toolPermission` value
      probed.
    * `--sandbox` does not change `init.permission_mode` (it still echoes
      whatever `toolPermission` says); see the Mapping section above for why
      it is no longer part of `:strict`'s argv despite once being. As on the
      Claude side these are *permission-layer* guards inside the agent, not OS
      isolation.

  ## Worker-protocol bootstrap allowlist (bd-25ivqe)

  `:strict` is allowlist-only (see the table above), but the Arbiter worker
  protocol itself is not optional: every worker and review-agent spawn reads
  its mailbox and prints its status via `arb` (`arb inbox`, `arb show`, `arb
  done`), and `Worker.PromptBuilder` routes both worker and reviewer prompts
  through read-only git (`git status`, `git diff`, `git log`) to orient
  themselves before doing anything else. Before this fix a `:strict` agy
  policy generated `permissions.allow: []` unless the operator happened to
  add rules of their own — so the worker's very first `run_command(arb
  inbox ...)` was auto-denied, and the run died at bootstrap with no shell
  at all (see bd-25ivqe's incident: probe run `6bf67d6b`).

  `allow_rules/1` therefore always unions a fixed worker-protocol baseline —
  `command(arb)`, `command(git status)`, `command(git diff)`, `command(git
  log)` — onto the operator's own `allow` rules, for *every* domain (worker
  and review-agent alike; this seam has no domain distinction to key off of,
  and a reviewer needs the same mailbox/orientation commands a worker does).
  This is deliberately narrower than "let agy run anything": it is exactly
  the read-only/status surface the worker protocol depends on, not a general
  shell escape hatch. It is emitted in every mode (not just `:strict`) since
  in `:auto`/`:bypass` the allow list is inert anyway (`toolPermission:
  "always-proceed"` lets everything through unless explicitly denied) — so
  baking it in unconditionally is simpler than mode-branching for no
  behavioural difference.

  This baseline does **not** weaken the deny list: agy's `permissions.deny`
  is a hard block "in every mode" (see the Honesty section above), so an
  operator who explicitly denies e.g. `command(arb)` still wins over this
  baseline allow — deny is checked independently of, and takes priority
  over, what `allow` names.

  `command(pwd)` is allowed alongside the baseline (bd-7wymls) but is not part
  of it: nothing *requires* it, and `bootstrap_command?/1` does not count it.
  It reads nothing but the cwd, and it is the command models chain first
  (`pwd && git status`). Probed live: agy checks **each part** of a chained
  command against the allow list, so with `command(pwd)` and `command(git
  status)` both allowed, `pwd && git status` runs. With only `git status`
  allowed, the whole line is soft-denied, which is what happened in run
  fc54ef4a. `ls`/`cat` are deliberately left out because they read arbitrary
  paths.

  ## A denied command ends the headless turn (bd-7wymls)

  `:strict` exists to deny commands, but headless agy does not let the model
  *continue* after a denial of this kind. Probed live against agy 1.2.11 in a
  throwaway `$HOME` with the `:strict` settings above (captures in
  `test/fixtures/agy_strict_denial_*.jsonl` and
  `agy_explicit_deny_continues.jsonl`):

    * **A command no `allow` rule names is *soft-denied*, and agy ends the
      turn.** agy would normally ask for approval, but it cannot prompt
      headlessly. The step comes back `DONE` with no output (or `ERROR`
      "user denied permission to run command" for a chained line). agy writes
      `jetski: no output produced — a tool required the "command" permission
      that headless mode cannot prompt for, so it was auto-denied…` to stderr,
      and the `result` event carries `denied_actions: [%{"action" =>
      "command", …}]`. The process then exits 0 before the model gets another
      step. This is deliberate upstream behaviour. agy's changelog says:
      "headless runs with `-p` silently skipping tool actions they were not
      permitted to take … now end with a notice naming the refused actions
      and report them as `denied_actions`".
    * **An explicit `permissions.deny` hit does *not* end the turn.** It
      comes back as an `ERROR` step ("Matches user-configured deny rule"),
      the model reads it as a tool error, and it carries on to its next
      step.
    * **So there is no agy flag or setting that turns the soft-deny into a
      tool error.** `agy --help` has none (`--sandbox` defeats the allowlist,
      see above; `--dangerously-skip-permissions` is `:bypass`). Denying
      everything with a catch-all `command(*)` would make every miss a hard,
      continuable deny, but deny outranks allow, so it also blocked the
      allowlisted `echo`. agy's rule grammar cannot express "deny whatever
      is not allowed".
    * **Resuming the conversation works.** `agy -p "<that was denied; don't
      retry; continue>" --conversation <id>` on the soft-denied conversation
      carried on: the model ran its next, allowed command and finished
      (`agy_strict_denial_resumed.jsonl`).

  Arbiter therefore relies on **resume-on-denial**. `Arbiter.Worker.ClaudeSession`
  marks a turn ended by a soft-deny from `result.denied_actions`, or from the
  stderr notice on a build that does not emit that field.
  `Arbiter.Worker` classifies the clean exit as `StopReason` category
  `:permission_denied` and resumes the same conversation (`--conversation`,
  bounded by `:resume_cap`). The resume prompt names the denied command and
  says not to retry it, to run one command per call, and to record findings
  and finish. The worker `GEMINI.md` (`Arbiter.Agents.Gemini.ConfigDir`)
  carries the same guidance, so the model tries to avoid the first denial
  too.

  ## Rule grammar

  agy's permission rules are `command(<prefix>)`, `read_file(<glob>)`,
  `write_file(<glob>)`, `read_url(<domain>)` and `execute_url(<domain>)` — not
  Claude's `Bash(...)`/`Read(...)`/`Write(...)`.

  Probed on agy 1.2.11 (bd-80talz), with a throwaway `$HOME`:

    * agy rewrites `settings.json` on load and **silently drops** a rule kind
      it does not know. `url(*)`, which this module emitted for a network-off
      policy and a bare `WebFetch` until then, was one of them, so neither
      deny ever reached the tool. `read_url(*)`, `execute_url(*)` and
      `execute_url(<domain>)` survive the rewrite, and `read_url(*)` blocks
      `read_url_content`.
    * A bare domain covers its subdomains: `read_url(catbox.moe)` blocked
      `https://files.catbox.moe/`, and `read_url(example.com)` blocked
      `https://example.com/` while `https://www.iana.org/` still loaded.
    * `command(...)` is a **literal prefix**. A glob inside it matches nothing:
      `command(echo *catbox.moe*)` and `command(printf *)` both let their
      commands run while `command(echo plain-ok)` blocked. So agy cannot deny
      a shell command by the host it names. `:no_public_upload` denies the
      upload-shaped `curl` prefixes (`curl -F`, `curl -T`, …) instead, which
      catches the incident's `curl -F … https://catbox.moe/…` but not a
      reordered command line. `SecurityPolicy`'s `safe_defaults`
  categories are expanded natively into that grammar, and the operator's own
  `allow`/`deny` strings are translated (a rule already written in agy's
  grammar passes through untouched). A *bare* Claude tool name (no `(...)`) is
  mapped onto the equivalent whole-path rule where agy has one — `Write` /
  `Edit` / `MultiEdit` / `NotebookEdit` → `write_file(**)`, `Read` →
  `read_file(**)`, `WebFetch` / `WebSearch` → `read_url(*)` — which is what keeps
  `Arbiter.Worker.Dispatch.review_security_policy/2`'s reviewer read-only
  posture working for agy. A rule with no agy analogue at all — `Monitor`,
  `ScheduleWakeup` — is **dropped** rather than emitted verbatim, since agy has
  no tool-name rule kind and an uninterpretable rule in the file is worse than
  an absent one.
  """

  alias Arbiter.Agents.SecurityPolicy

  @doc """
  The permission-mode argv fragment for a policy.

    * `:bypass` → `["--dangerously-skip-permissions"]`
    * `:auto`   → `[]` (the generated settings carry the posture)
    * `:strict` → `[]` (see bd-25ivqe: `--sandbox` disables the allowlist gate)
  """
  @spec permission_argv(SecurityPolicy.t()) :: [String.t()]
  def permission_argv(%SecurityPolicy{permissions: %{mode: :bypass}}),
    do: ["--dangerously-skip-permissions"]

  def permission_argv(%SecurityPolicy{}), do: []

  @doc """
  The agy `toolPermission` value for a policy — the string agy echoes back as
  `init.permission_mode`.

  `:strict` deliberately never resolves to `"always-proceed"`: that value being
  reported for a `:strict` spawn is the exact defect bd-7s29yq closes. It also
  never resolves to agy's own `"strict"` value — see bd-25ivqe: that value
  auto-denies every tool call in headless mode regardless of
  `permissions.allow` content. `"proceed-in-sandbox"` is the value that
  actually consults the allow list headlessly.
  """
  @spec tool_permission(SecurityPolicy.t()) :: String.t()
  def tool_permission(%SecurityPolicy{permissions: %{mode: :strict}}), do: "proceed-in-sandbox"
  def tool_permission(%SecurityPolicy{}), do: "always-proceed"

  @doc """
  The generated agy settings document for a policy, as a string-keyed map.

  Options:

    * `:worktree` — the spawn's worktree. When given it is listed in
      `trustedWorkspaces` so agy never gates the run on folder trust.
  """
  @spec settings(SecurityPolicy.t(), keyword()) :: map()
  def settings(%SecurityPolicy{} = policy, opts \\ []) do
    %{
      "toolPermission" => tool_permission(policy),
      # Emitted because it is the documented switch, but see the moduledoc:
      # probing showed it does not actually block out-of-worktree access.
      "allowNonWorkspaceAccess" => false,
      "permissions" => %{
        "allow" => allow_rules(policy),
        "deny" => deny_rules(policy)
      }
    }
    |> maybe_put_trusted(Keyword.get(opts, :worktree))
  end

  @doc "`settings/2`, pretty-printed as JSON — the bytes written to disk."
  @spec settings_json(SecurityPolicy.t(), keyword()) :: String.t()
  def settings_json(%SecurityPolicy{} = policy, opts \\ []),
    do: policy |> settings(opts) |> Jason.encode!(pretty: true)

  @doc """
  The full, deduped agy deny-rule list for a policy: the expanded
  `safe_defaults` baseline + the operator's `deny` rules + sandbox-derived
  denies, all in agy's grammar.
  """
  @spec deny_rules(SecurityPolicy.t()) :: [String.t()]
  def deny_rules(%SecurityPolicy{permissions: perms, sandbox: sandbox}) do
    (Enum.flat_map(perms.safe_defaults, &expand_category/1) ++
       translate_all(perms.deny) ++
       sandbox_deny(sandbox))
    |> Enum.uniq()
  end

  # The Arbiter worker protocol's own required commands — see the moduledoc
  # section "Worker-protocol bootstrap allowlist". Always present regardless
  # of domain (worker vs. review-agent) or mode.
  @worker_bootstrap_commands ["arb", "git status", "git diff", "git log"]
  @worker_bootstrap_allow Enum.map(@worker_bootstrap_commands, &"command(#{&1})")

  # bd-7wymls: allowed alongside the bootstrap set but NOT "required" by the
  # protocol. `pwd` is the orientation command models reach for first
  # (`pwd && git status` was the second denial in run fc54ef4a) and reads
  # nothing but the cwd. Deliberately not `ls`/`cat`: those read arbitrary
  # paths, which `:strict`'s allowlist exists to gate.
  @harmless_allow ["command(pwd)"]

  @doc """
  Whether `command_line` is one of the worker-protocol bootstrap commands
  (`arb`, `git status`, `git diff`, `git log`) — i.e. a command the protocol
  *requires*, so a `:strict` denial of it is a policy misconfiguration rather
  than the policy doing its job. Matched the way agy matches a
  `command(<prefix>)` rule: whole leading words. A chained line (`&&`, `;`,
  `|`) is never bootstrap, even if its first part is (bd-7wymls: `pwd && git
  status` must not be reported as a "required" command).
  """
  @spec bootstrap_command?(String.t() | nil) :: boolean()
  def bootstrap_command?(command_line) when is_binary(command_line) do
    line = String.trim(command_line)

    not String.contains?(line, ["&&", ";", "|", "\n"]) and
      Enum.any?(@worker_bootstrap_commands, fn prefix ->
        line == prefix or String.starts_with?(line, prefix <> " ")
      end)
  end

  def bootstrap_command?(_), do: false

  @doc """
  The full agy `allow` list for a policy: the worker-protocol bootstrap
  baseline (`arb`, plus the read-only git the worker/review prompts require)
  and `pwd` (bd-7wymls), unioned with the operator's own `allow` rules
  translated into agy's grammar.

  Load-bearing under `:strict`, where headless agy auto-denies everything
  these rules do not name — without the baseline a `:strict` agy worker
  cannot even read its own mailbox (bd-25ivqe).
  """
  @spec allow_rules(SecurityPolicy.t()) :: [String.t()]
  def allow_rules(%SecurityPolicy{permissions: perms}),
    do: (@worker_bootstrap_allow ++ @harmless_allow ++ translate_all(perms.allow)) |> Enum.uniq()

  # ---- internals ---------------------------------------------------------

  defp maybe_put_trusted(settings, wt) when is_binary(wt) and wt != "",
    do: Map.put(settings, "trustedWorkspaces", [wt])

  defp maybe_put_trusted(settings, _), do: settings

  # Recursive force-deletes. agy `command(...)` rules match a command *prefix*,
  # so `command(rm -rf)` blocks `rm -rf <anything>`. As on the Claude side this
  # enumerates the common spellings; it is a safety net, not a proof.
  defp expand_category(:no_destructive_fs) do
    [
      "command(rm -rf)",
      "command(rm -fr)",
      "command(rm -r -f)",
      "command(rm -f -r)",
      "command(rm -Rf)",
      "command(sudo rm)",
      "command(mkfs)",
      "command(dd)"
    ]
  end

  # Force pushes wedge shared branches. `--force-with-lease` is intentionally
  # not denied.
  defp expand_category(:no_force_push) do
    ["command(git push --force)", "command(git push -f)"]
  end

  defp expand_category(:no_secret_reads) do
    [
      "read_file(**/.env)",
      "read_file(**/.env.*)",
      "read_file(**/*.pem)",
      "read_file(**/*_rsa)",
      "read_file(**/id_rsa)",
      "read_file(**/id_ed25519)",
      "read_file(**/.ssh/**)",
      "read_file(**/.aws/credentials)",
      "read_file(**/.netrc)",
      "read_file(**/.npmrc)",
      "read_file(**/secrets/**)",
      "command(cat .env)",
      "command(cat ~/.ssh)"
    ]
  end

  # Writes to sensitive paths outside the worktree. `~/.gemini/**` is the agy
  # addition: a worker that can rewrite its own generated settings.json could
  # otherwise lift its own posture between turns.
  defp expand_category(:no_outside_writes) do
    [
      "write_file(/etc/**)",
      "write_file(/usr/**)",
      "write_file(~/.ssh/**)",
      "write_file(~/.gemini/**)",
      "write_file(~/.claude/**)",
      "write_file(~/.config/**)"
    ]
  end

  # The MergeQueue owns PR creation (bd-53xrmi).
  defp expand_category(:no_pr_create) do
    ["command(gh pr create)", "command(glab mr create)"]
  end

  # bd-d534xo's Claude rules deny the `Monitor`/`ScheduleWakeup` *tools* by
  # name. agy's rule grammar has no tool-name kind at all (only
  # command/read_file/write_file/url), so there is nothing to emit here — the
  # agy analogue is prompt-level only, via
  # `Arbiter.Agents.Gemini.async_tool_instruction/0`.
  defp expand_category(:no_async_wait), do: []

  # bd-80talz: agy's URL tools by domain (subdomains included, see the
  # moduledoc), and the shell's upload paths by literal prefix: `command(...)`
  # cannot match a host in the middle of a command line.
  defp expand_category(:no_public_upload) do
    Enum.flat_map(
      SecurityPolicy.public_upload_hosts(),
      &["read_url(#{&1})", "execute_url(#{&1})"]
    ) ++
      [
        "command(curl -F)",
        "command(curl --form)",
        "command(curl -T)",
        "command(curl --upload-file)"
      ]
  end

  defp expand_category(:no_gh_publish) do
    ["command(gh gist create)", "command(gh gist edit)", "command(gh issue comment)"]
  end

  defp expand_category(_unknown), do: []

  # When the policy cuts network, deny agy's URL tools and the obvious shell
  # egress commands. (Permission-level: git/package-manager traffic isn't
  # blocked here — that needs an OS sandbox; see moduledoc.)
  defp sandbox_deny(%{network: false}) do
    [
      "read_url(*)",
      "execute_url(*)",
      "command(curl)",
      "command(wget)",
      "command(nc)",
      "command(ncat)",
      "command(telnet)"
    ]
  end

  defp sandbox_deny(_sandbox), do: []

  defp translate_all(rules) when is_list(rules),
    do: rules |> Enum.map(&translate/1) |> Enum.reject(&is_nil/1)

  defp translate_all(_), do: []

  @agy_kinds ~w(command read_file write_file read_url execute_url)

  # Claude grammar in, agy grammar out. A rule already written agy-style passes
  # through; anything we cannot express is dropped (see moduledoc).
  defp translate(rule) when is_binary(rule) do
    case Regex.run(~r/\A([A-Za-z_]+)\((.*)\)\z/s, String.trim(rule)) do
      [_, kind, _inner] when kind in @agy_kinds ->
        String.trim(rule)

      # `url(...)` is not an agy kind; agy drops it on load (bd-80talz).
      [_, "url", inner] ->
        "read_url(" <> inner <> ")"

      [_, "Bash", inner] ->
        "command(" <> strip_trailing_glob(inner) <> ")"

      [_, "Read", inner] ->
        "read_file(" <> inner <> ")"

      [_, kind, inner] when kind in ["Write", "Edit", "MultiEdit"] ->
        "write_file(" <> inner <> ")"

      [_, "WebFetch", inner] ->
        web_fetch_rule(inner)

      _ ->
        bare_tool_rule(String.trim(rule))
    end
  end

  defp translate(_), do: nil

  # A bare Claude tool name — no `(...)` argument — as emitted by
  # `Arbiter.Worker.Dispatch.review_security_policy/2`, which merges
  # `deny: ["Edit", "Write", "NotebookEdit"]` into *every* worktree-backed
  # review dispatch so "you are not the author; do not modify the branch" is a
  # property of the spawn rather than a prompt line. Those three DO have an agy
  # analogue — agy's `write_to_file` / `replace_file_content` /
  # `multi_replace_file_content` are all governed by `write_file(<glob>)` — so
  # dropping them would hand an agy reviewer write access to the branch it is
  # reviewing while the same policy blocks a Claude reviewer.
  #
  # `**` is agy's match-everything path glob (cf. the `write_file(/etc/**)`
  # baseline above): a bare tool name in Claude's grammar means "this tool, for
  # any argument", so the whole-path glob is the faithful translation in both
  # directions (deny ⇒ never, allow ⇒ unrestricted).
  defp bare_tool_rule(rule) when rule in ["WebFetch", "WebSearch"], do: "read_url(*)"

  defp bare_tool_rule(rule) when rule in ["Write", "Edit", "MultiEdit", "NotebookEdit"],
    do: "write_file(**)"

  defp bare_tool_rule("Read"), do: "read_file(**)"
  defp bare_tool_rule(_), do: nil

  # `WebFetch(domain:example.com)` names one domain, and agy's `read_url` takes
  # the same bare domain. Anything else Claude accepts there has no agy
  # analogue narrower than every URL.
  defp web_fetch_rule(inner) do
    case Regex.run(~r/\Adomain:([A-Za-z0-9.-]+)\z/, String.trim(inner)) do
      [_, domain] -> "read_url(" <> domain <> ")"
      _ -> "read_url(*)"
    end
  end

  # `rm -rf:*` (Claude's "command prefix up to `:`, then a glob") → `rm -rf`.
  defp strip_trailing_glob(inner) do
    inner
    |> String.replace(~r/:\*\z/, "")
    |> String.trim()
  end
end
