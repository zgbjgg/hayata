defmodule HayataRouterDecisionExample.Agent do
  use Hayata.Agent

  agent do
    id "router_decision_agent"

    state %{
      messages: []
    }

    node "router", context do
      message = Map.get(context, :input, "")
      normalized = String.downcase(message)

      route =
        case String.contains?(normalized, "hola") or
               String.contains?(normalized, "saludo") do
          true -> :go_to_greeting
          false -> :go_to_math
        end

      %{route: route}
    end

    node "greeting_processor", context do
      append_ai_message(
        context,
        "¡Hola! ¿En qué puedo ayudarte hoy?"
      )
    end

    node "math_processor", context do
      append_ai_message(
        context,
        "El resultado de 2 + 2 es 4."
      )
    end

    decision do
      on_step 0, context do
        next "router", input: context.input
      end

      on_step _step, %{step: 1, state: %{route: :go_to_greeting}} do
        next "greeting_processor", input: :input
      end

      on_step _step, %{step: 1, state: %{route: :go_to_math}} do
        next "math_processor", input: :input
      end

      on_step 2, context do
        finish context.state
      end
    end

    max_steps 5
  end

  defp append_ai_message(context, content) do
    messages = Map.get(context, :messages, [])
    input = Map.get(context, :input, "")

    user_message = %{role: :user, content: input}
    ai_message = %{role: :ai, content: content}

    %{messages: messages ++ [user_message, ai_message]}
  end
end

defmodule HayataRouterDecisionExample do
  def run(message) when is_binary(message) do
    case Hayata.Agent.start_link(HayataRouterDecisionExample.Agent.config()) do
      {:ok, supervisor_pid} ->
        run_agent(supervisor_pid, message)

      {:error, reason} ->
        {:error, {:agent_start_failed, reason}}
    end
  end

  defp run_agent(supervisor_pid, message) do
    try do
      case Hayata.Agent.run(supervisor_pid, message, %{subscriber: self()}) do
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
