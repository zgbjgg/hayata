defmodule Hayata.Agent do
  @moduledoc """
  Elixir API for starting and interacting with Hayata agents.

  Each agent runs in its own Erlang/OTP supervision tree.
  """

  defmacro __using__(_options) do
    quote do
      import Hayata.Agent.DSL, only: [agent: 1]
    end
  end

  @type config :: %{
          required(:id) => term(),
          required(:nodes) => %{optional(term()) => function()},
          optional(:state) => map(),
          optional(:decision_policy) => function(),
          optional(:max_steps) => pos_integer(),
          optional(:execution_timeout) => pos_integer(),
          optional(:llm) => map(),
          optional(:conversation_memory) => boolean(),
          optional(:rag_config) => map()
        }

  @doc """
  Returns an OTP child specification for a Hayata agent.

  The agent supervision tree becomes a direct child of the
  supervisor that starts this specification.
  """
  @spec child_spec(config()) :: map()
  def child_spec(config) when is_map(config) do
    %{
      id: Map.get(config, :id, __MODULE__),
      start: {__MODULE__, :start_link, [config]},
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor
    }
  end

  @doc """
  Starts a Hayata agent supervision tree.

  This function is intended to be called by an Elixir supervisor.
  """
  @spec start_link(config()) ::
          {:ok, pid()} | :ignore | {:error, term()}
  def start_link(config) when is_map(config) do
    :hayata_agent_sup.start_link(config)
  end

  @doc """
  Returns the PID of the agent coordinator.
  """
  @spec coordinator(pid()) :: {:ok, pid()} | {:error, term()}
  def coordinator(agent_sup_pid) when is_pid(agent_sup_pid) do
    :hayata_agent_sup.agent(agent_sup_pid)
  end

  @doc """
  Starts an asynchronous agent invocation.

  Optional run options are the same options accepted by
  `:hayata_agent.run/3`, including `:subscriber` and `:stream`.
  """
  @spec run(pid(), term(), map()) ::
          {:ok, reference()} | {:error, term()}
  def run(agent_sup_pid, input, options \\ %{})
      when is_pid(agent_sup_pid) and is_map(options) do
    case coordinator(agent_sup_pid) do
      {:ok, agent_pid} ->
        :hayata_agent.run(agent_pid, input, options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the result of the most recent invocation, if available.

  Returns `{:error, :no_result}` while the invocation is still running
  or before the first invocation.
  """
  @spec result(pid()) :: {:ok, term()} | {:error, term()}
  def result(agent_sup_pid) when is_pid(agent_sup_pid) do
    case coordinator(agent_sup_pid) do
      {:ok, agent_pid} ->
        :hayata_agent.get_result(agent_pid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current agent state.
  """
  @spec state(pid()) :: map() | {:error, term()}
  def state(agent_sup_pid) when is_pid(agent_sup_pid) do
    case coordinator(agent_sup_pid) do
      {:ok, agent_pid} ->
        :hayata_agent.get_state(agent_pid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns operational information about the agent.
  """
  @spec info(pid()) :: map() | {:error, term()}
  def info(agent_sup_pid) when is_pid(agent_sup_pid) do
    case coordinator(agent_sup_pid) do
      {:ok, agent_pid} ->
        :hayata_agent.get_info(agent_pid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Attempts to recover an invocation that requires recovery.
  """
  @spec recover(pid()) :: {:ok, reference()} | {:error, term()}
  def recover(agent_sup_pid) when is_pid(agent_sup_pid) do
    case coordinator(agent_sup_pid) do
      {:ok, agent_pid} ->
        :hayata_agent.recover(agent_pid)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
