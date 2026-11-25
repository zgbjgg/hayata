defmodule HayataParallelExample.Agent do
  use Hayata.Agent

  agent do
    id "parallel_example"

    state %{
      input: "",
      results: []
    }

    node "node_a", context do
      input = context.input
      Process.sleep(1_000)

      %{
        results: ["Result from A: #{input}"]
      }
    end

    node "node_b", context do
      input = context.input

      %{
        results: ["Result from B: #{input}"]
      }
    end

    node "aggregator", context do
      results = context.input.results

      output_strings =
        results
        |> Enum.flat_map(fn result -> result.results end)

      %{
        results: output_strings ++ ["Finalized Workflow"]
      }
    end

    decision do
      on_step 0, context do
        parallel ["node_a", "node_b"], input: context.state.input
      end

      on_step 2, context do
        next "aggregator", input: %{results: context.parallel_results}
      end

      on_step 3, context do
        finish context.state
      end
    end

    max_steps 4
    execution_timeout 5_000
  end
end

defmodule HayataParallelExample do
  def run do
    run("Hello Hayata")
  end

  def run(input) when is_binary(input) do
    config =
      HayataParallelExample.Agent.config()
      |> Map.update!(:state, fn state -> Map.put(state, :input, input) end)

    case Hayata.Agent.start_link(config) do
      {:ok, supervisor_pid} ->
        run_agent(supervisor_pid)

      {:error, reason} ->
        {:error, {:agent_start_failed, reason}}
    end
  end

  defp run_agent(supervisor_pid) do
    try do
      case Hayata.Agent.run(supervisor_pid, :start, %{subscriber: self()}) do
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
      10_000 ->
        {:error, :notification_timeout}
    end
  end
end
