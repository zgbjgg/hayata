defmodule HayataStreamExample.Agent do
  use Hayata.Agent

  agent do
    id "streaming_example"

    state %{}

    node "streaming_node", context do
      streamer = context.hayata_streamer

      IO.puts("Node started processing.")

      :ok = streamer.(%{chunk: "Hello"})
      Process.sleep(500)

      :ok = streamer.(%{chunk: " from"})
      Process.sleep(500)

      :ok = streamer.(%{chunk: " Hayata!"})

      %{answer: "Hello from Hayata!"}
    end

    decision do
      on_step 0 do
        next "streaming_node", input: %{}
      end

      on_step 1, context do
        finish context.state
      end
    end

    max_steps 3
    execution_timeout 5_000
  end
end

defmodule HayataStreamExample do
  def run do
    case Hayata.Agent.start_link(HayataStreamExample.Agent.config()) do
      {:ok, supervisor_pid} ->
        run_agent(supervisor_pid)

      {:error, reason} ->
        {:error, {:agent_start_failed, reason}}
    end
  end

  defp run_agent(supervisor_pid) do
    try do
      case Hayata.Agent.run(
             supervisor_pid,
             %{input: "Start streaming"},
             %{subscriber: self(), stream: true}
           ) do
        {:ok, invocation_id} ->
          IO.inspect(invocation_id, label: "Invocation started")
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
      {:hayata_agent_event, ^invocation_id, event} ->
        print_event(event)
        await_result(invocation_id)

      {:hayata_agent_result, ^invocation_id, {:ok, result}} ->
        IO.inspect(result, label: "Final result")
        {:ok, result}

      {:hayata_agent_result, ^invocation_id, {:error, reason}} ->
        IO.inspect(reason, label: "Invocation failed")
        {:error, reason}
    after
      50_000 ->
        {:error, :notification_timeout}
    end
  end

  defp print_event(event) do
    IO.puts("[#{event.sequence}] #{event.type}: #{inspect(event.data)}")
  end
end
