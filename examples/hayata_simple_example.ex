defmodule HayataSimpleExample.Agent do
  use Hayata.Agent

  agent do
    id "hello_agent"

    state %{}

    node "mock_llm", context do
      message = Map.get(context, :input, "Hola")

      %{
        messages: [
          %{role: :ai, content: "¡Hola mundo!"},
          %{role: :user, content: message}
        ]
      }
    end

    decision do
      on_step 0, _context do
        next "mock_llm", input: "Hola"
      end

      on_step 1, context do
        finish context.state
      end
    end

    max_steps 3
    execution_timeout 5_000
  end
end

defmodule HayataSimpleExample do
  @invocation_input %{input: "Hola"}
  @invocation_timeout 5_000

  def run do
    case Hayata.Agent.start_link(HayataSimpleExample.Agent.config()) do
      {:ok, agent_supervisor_pid} ->
        run_agent(agent_supervisor_pid)

      {:error, reason} ->
        {:error, {:agent_start_failed, reason}}
    end
  end

  defp run_agent(agent_supervisor_pid) do
    try do
      start_invocation(agent_supervisor_pid)
    after
      Hayata.Agent.stop(agent_supervisor_pid)
    end
  end

  defp start_invocation(agent_supervisor_pid) do
    case Hayata.Agent.run(
           agent_supervisor_pid,
           @invocation_input,
           %{subscriber: self()}
         ) do
      {:ok, invocation_id} ->
        await_result(invocation_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_result(invocation_id) do
    receive do
      {:hayata_agent_result, ^invocation_id, {:ok, result}} ->
        {:ok, result}

      {:hayata_agent_result, ^invocation_id, {:error, reason}} ->
        {:error, reason}
    after
      @invocation_timeout ->
        {:error, :notification_timeout}
    end
  end
end
