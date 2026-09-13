defmodule ArbiterWeb.CoreComponents.Markdown do
  @moduledoc """
  Renders untrusted markdown as sanitized HTML.

  Every markdown-bearing field in the dashboard (task `description`, `notes`,
  `qa_notes`, `deployment_notes`, `pr_body`, review `findings_summary`) is
  written by workers (LLM output, which can echo prompt-injected or
  tracker-sourced content), by tracker integrations pulling external issue
  bodies, or by humans. All of it is **untrusted input** and is treated as
  such:

    * raw inline HTML is never trusted — `render: [unsafe_: false]` (comrak's
      default) means raw HTML in the source is dropped rather than emitted;
    * the rendered HTML is then run through MDEx's built-in `ammonia`
      sanitizer as a second, independent layer (tag + attribute allowlist,
      `<script>`/`<style>` content removed, event-handler attributes dropped);
    * URL schemes are narrowed to `http`/`https`/`mailto`, which kills
      `javascript:` and `data:` payloads in both `href` and `src`;
    * links get `rel="noopener noreferrer"`.

  > #### The one `raw/1` call site {: .warning}
  >
  > `Phoenix.HTML.raw/1` is applied to markdown-derived HTML in exactly ONE
  > place in this codebase: `render_markdown/1` below. Every surface that
  > displays markdown calls `<.markdown text={...} />` instead of rendering
  > markdown itself, so "did we sanitize?" stays a one-file audit. Do not add
  > another `raw/1` on markdown output anywhere else.

  Note: images are allowed with `http`/`https` sources, matching how trackers
  (GitHub/Jira) embed screenshots in issue bodies. A remote image in a task
  body is therefore a tracking-pixel / referrer-leak vector for whoever
  authored it — low severity for a single-operator dashboard, but the reason
  the scheme allowlist above matters.
  """
  use Phoenix.Component

  # GFM: tables, task lists, strikethrough and bare-URL autolinks are what
  # worker- and tracker-authored markdown actually uses.
  @extension [
    table: true,
    tasklist: true,
    strikethrough: true,
    autolink: true
  ]

  @render [
    # Never emit raw inline HTML from the source document. This is comrak's
    # default; it is spelled out because flipping it would be the bug.
    unsafe_: false,
    escape: false
  ]

  # Layered on top of ammonia's defaults (see `MDEx.Document.default_sanitize_options/0`):
  # `input` is re-allowed — with a three-attribute allowlist — purely so GFM
  # task lists keep their checkboxes, and URL schemes are narrowed from
  # ammonia's permissive default set to the three that make sense here.
  @sanitize [
    add_tags: ["input"],
    add_tag_attributes: %{"input" => ["type", "checked", "disabled"]},
    url_schemes: ["http", "https", "mailto"],
    link_rel: "noopener noreferrer"
  ]

  @doc """
  Renders a markdown string as sanitized HTML.

  Blank or `nil` text renders nothing at all, so call sites can pass a field
  straight through without guarding.

  ## Examples

      <.markdown text={@task.description} />
      <.markdown text={@task.notes} class="mt-2" id="task-notes-md" />
  """
  attr :text, :string, default: nil, doc: "the untrusted markdown source"
  attr :class, :any, default: nil, doc: "extra classes for the wrapper element"
  attr :id, :string, default: nil, doc: "optional DOM id for the wrapper element"
  attr :rest, :global

  def markdown(assigns) do
    ~H"""
    <div :if={present?(@text)} id={@id} class={["markdown-body", @class]} {@rest}>
      {render_markdown(@text)}
    </div>
    """
  end

  @doc """
  Converts markdown to sanitized HTML.

  This is the only function in the codebase that calls `Phoenix.HTML.raw/1`
  on markdown-derived HTML — see the module doc. It is public so it can be
  tested directly, not so it can be called from templates; use `markdown/1`.
  """
  # Sobelow flags `raw/1` on a variable as XSS.Raw (low confidence), which is
  # the right default: unescaped HTML built at runtime is how XSS happens.
  # This is the deliberate, audited exception — the variable below is MDEx
  # output that has just been through comrak with raw HTML disabled AND the
  # ammonia sanitizer with a narrowed URL-scheme allowlist (see the moduledoc
  # and the XSS tests in markdown_test.exs). Annotated on the one function
  # that earns it rather than added to .sobelow-conf's `ignore` list, so a new
  # `raw/1` anywhere else in the app still fails the scan.
  # sobelow_skip ["XSS.Raw"]
  def render_markdown(text) when is_binary(text) do
    case MDEx.to_html(text, extension: @extension, render: @render, sanitize: @sanitize) do
      {:ok, html} ->
        Phoenix.HTML.raw(html)

      {:error, _reason} ->
        # Never let malformed input take a dashboard page down: fall back to
        # the pre-markdown behavior, escaped by HEEx as plain text.
        text
    end
  end

  def render_markdown(_), do: ""

  defp present?(text) when is_binary(text), do: String.trim(text) != ""
  defp present?(_), do: false
end
