defmodule Hayata.AgentTest do
  use ExUnit.Case, async: false

  describe "child_spec/1" do
    test "builds a supervisor child specification" do
      config = agent_config()

      child_spec = Hayata.Agent.child_spec(config)

      assert child_spec.id == config.id
      assert child_spec.type == :supervisor
      assert child_spec.restart == :permanent
      assert child_spec.shutdown == :infinity
      assert child_spec.start == {Hayata.Agent, :start_link, [config]}
    end
  end

  describe "start_link/1" do
    test "starts an agent under an Elixir supervisor" do
      config = agent_config()

      {supervisor_pid, agent_sup_pid} =
        start_agent_supervisor(config)

      assert Process.alive?(supervisor_pid)
      assert Process.alive?(agent_sup_pid)

      assert {:ok, agent_pid} =
               Hayata.Agent.coordinator(agent_sup_pid)

      assert Process.alive?(agent_pid)
    end
  end

  describe "run/3" do
    test "runs an agent and returns its result" do
      config = agent_config()

      {_supervisor_pid, agent_sup_pid} =
        start_agent_supervisor(config)

      assert {:ok, invocation_id} =
               agent_sup_pid
               |> Hayata.Agent.run(%{})

      assert is_reference(invocation_id)

      assert {:ok, %{answer: "Hello from Hayata: Elixir"}} =
               await_result(agent_sup_pid, 100)
    end
  end

  describe "state/1 and info/1" do
    test "returns the current state and operational information" do
      config = agent_config()

      {_supervisor_pid, agent_sup_pid} =
        start_agent_supervisor(config)

      assert %{} = Hayata.Agent.state(agent_sup_pid)

      assert %{status: :ready} =
               Hayata.Agent.info(agent_sup_pid)
    end
  end

  describe "supervision lifecycle" do
    test "stops the complete agent tree with its parent supervisor" do
      config = agent_config()

      {supervisor_pid, agent_sup_pid} =
        start_agent_supervisor(config)

      monitor_ref = Process.monitor(agent_sup_pid)

      assert :ok = Supervisor.stop(supervisor_pid)

      assert_receive(
        {:DOWN, ^monitor_ref, :process, ^agent_sup_pid, _reason},
        1000
      )

      refute Process.alive?(agent_sup_pid)
    end
  end

  defp agent_config do
    %{
      id: {:agent_test, make_ref()},
      state: %{},
      nodes: %{
        greeting: fn state ->
          input = Map.fetch!(state, :input)
          %{answer: "Hello from Hayata: #{input}"}
        end
      },
      decision_policy: fn context ->
        case Map.fetch!(context, :step) do
          0 -> {:next, :greeting, "Elixir"}
          1 -> {:finish, Map.fetch!(context, :state)}
        end
      end,
      max_steps: 3,
      execution_timeout: 5000
    }
  end

  defp start_agent_supervisor(config) do
    children = [
      Hayata.Agent.child_spec(config)
    ]

    {:ok, supervisor_pid} =
      Supervisor.start_link(
        children,
        strategy: :one_for_one
      )

    Process.unlink(supervisor_pid)

    on_exit(fn ->
      Process.exit(supervisor_pid, :shutdown)
    end)

    [{_id, agent_sup_pid, :supervisor, _modules}] =
      Supervisor.which_children(supervisor_pid)

    {supervisor_pid, agent_sup_pid}
  end

  defp await_result(agent_sup_pid, attempts) when attempts > 0 do
    case Hayata.Agent.result(agent_sup_pid) do
      {:error, :no_result} ->
        Process.sleep(10)
        await_result(agent_sup_pid, attempts - 1)

      result ->
        result
    end
  end

  defp await_result(_agent_sup_pid, 0) do
    {:error, :timeout}
  end
end
