defmodule HayataCycleExample.Agent do
  use Hayata.Agent

  agent do
    id "cycle_example"

    state %{
      counter: 0,
      historial: [],
      last_node: nil
    }

    node "node_a", context do
      counter = Map.get(context, :counter, 0)
      history = Map.get(context, :historial, [])

      IO.puts("--- Executing Node A (Current counter: #{counter}) ---")

      %{
        counter: counter + 1,
        historial: history ++ ["Passed through A"],
        last_node: :node_a
      }
    end

    node "node_b", context do
      counter = Map.get(context, :counter, 0)
      history = Map.get(context, :historial, [])

      IO.puts("--- Executing Node B (Current counter: #{counter}) ---")

      %{
        counter: counter + 1,
        historial: history ++ ["Passed through B"],
        last_node: :node_b
      }
    end

    decision do
      on_step 0 do
        next "node_a", input: %{}
      end

      on_step 1 do
        next "node_b", input: %{}
      end

      on_step 2 do
        next "node_a", input: %{}
      end

      on_step 3 do
        next "node_b", input: %{}
      end

      on_step 4, context do
        finish context.state
      end
    end

    max_steps 10
    execution_timeout 5_000
  end
end

defmodule HayataCycleExample do
  @timeout 10_000

  def run do
    case Hayata.Agent.start_link(HayataCycleExample.Agent.config()) do
      {:ok, supervisor_pid} ->
        run_agent(supervisor_pid)

      {:error, reason} ->
        {:error, {:agent_start_failed, reason}}
    end
  end

  defp run_agent(supervisor_pid) do
    try do
      case Hayata.Agent.run(supervisor_pid, %{}, %{subscriber: self()}) do
        {:ok, invocation_id} ->
          await_result(invocation_id)

        {:error, reason} ->
          {:error, reason}
      end
    after
      Hayata.Agent.stop(supervisor_pid)
    end
  end

  defp await_result(invocation_id) do
    receive do
      {:hayata_agent_result, ^invocation_id, {:ok, result}} ->
        {:ok, result}

      {:hayata_agent_result, ^invocation_id, {:error, reason}} ->
        {:error, reason}
    after
      @timeout ->
        {:error, :notification_timeout}
    end
  end
end
