defmodule ArbiterWeb.Api.MessageJSON do
  @moduledoc """
  Render functions for Message resources.

  Atoms are emitted as strings; timestamps as ISO8601.
  """

  alias Arbiter.Messages.Message

  @doc "Renders a single message."
  def show(%{message: message}), do: data(message)

  @doc "Renders a list of messages wrapped under :data."
  def index(%{messages: messages}) do
    %{data: Enum.map(messages, &data/1)}
  end

  def data(%Message{} = m) do
    %{
      id: m.id,
      kind: to_string_atom(m.kind),
      from_ref: m.from_ref,
      to_ref: m.to_ref,
      workspace_id: m.workspace_id,
      subject: m.subject,
      body: m.body,
      read_at: iso(m.read_at),
      inserted_at: iso(m.inserted_at),
      updated_at: iso(m.updated_at)
    }
  end

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
