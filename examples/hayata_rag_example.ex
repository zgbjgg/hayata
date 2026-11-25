defmodule HayataRagExample.Agent do
  use Hayata.Agent

  agent do
    id "hayata_rag_agent"

    state %{}

    llm %{
      adapter: :hayata_openai,
      model: "gpt-4o-mini",
      provider_config: %{
        api_key: System.get_env("OPENAI_API_KEY")
      }
    }

    rag_config %{
      retrieve: &HayataRagExample.retrieve_documents/2
    }

    node "agent", context do
      tool_loop = context.hayata_tool_loop
      rag = context.hayata_rag

      search_tool = %{
        name: "search_knowledge",
        description:
          "Searches the Hayata documentation knowledge base. " <>
            "Use this tool whenever the user asks about Hayata's architecture, " <>
            "features, execution model, RAG, LLM integration, tools, or recovery. " <>
            "Use the returned documents as the primary source. Do not invent details.",
        parameters: %{
          type: :object,
          properties: %{
            query: %{
              type: :string,
              description: "A concise query about a Hayata concept or feature."
            }
          },
          required: ["query"]
        },
        handler: fn arguments ->
          rag.(Map.fetch!(arguments, "query"), %{limit: 5})
        end
      }

      request = %{
        messages: [
          %{
            role: :user,
            content: [
              %{type: :text, text: context.input}
            ]
          }
        ]
      }

      case tool_loop.(request, [search_tool], 5) do
        {:ok, result} ->
          %{answer: result.response}

        {:error, reason} ->
          %{error: reason}
      end
    end

    decision do
      on_step 0, context do
        next "agent", input: context.input
      end

      on_step 1, context do
        finish context.state
      end
    end

    max_steps 5
    execution_timeout 60_000
  end
end

defmodule HayataRagExample do
  def run(question) when is_binary(question) do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        {:error, :missing_openai_api_key}

      "" ->
        {:error, :missing_openai_api_key}

      _api_key ->
        case Application.ensure_all_started(:hayata) do
          {:ok, _started} ->
            run_agent(question)

          {:error, reason} ->
            {:error, {:application_start_failed, reason}}
        end
    end
  end

  def retrieve_documents(query, options) do
    tokens = query_tokens(query)

    documents =
      knowledge_base()
      |> Enum.map(fn document ->
        Map.put(
          document,
          :score,
          relevance_score(tokens, document.content)
        )
      end)
      |> Enum.filter(fn document -> document.score > 0 end)
      |> Enum.sort_by(
        fn document -> {-document.score, document.id} end
      )

    limit = Map.get(options, :limit, 5)

    {:ok, %{documents: Enum.take(documents, limit)}}
  end

  defp run_agent(question) do
    case Hayata.Agent.start_link(HayataRagExample.Agent.config()) do
      {:ok, supervisor_pid} ->
        try do
          case Hayata.Agent.run(
                 supervisor_pid,
                 question,
                 %{subscriber: self()}
               ) do
            {:ok, invocation_id} ->
              await_result(invocation_id)

            {:error, reason} ->
              {:error, reason}
          end
        after
          Hayata.Agent.stop(supervisor_pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_result(invocation_id) do
    receive do
      {:hayata_agent_result, ^invocation_id, {:ok, result}} ->
        print_answer(result)
        {:ok, result}

      {:hayata_agent_result, ^invocation_id, {:error, reason}} ->
        {:error, reason}
    after
      60_000 ->
        {:error, :invocation_timeout}
    end
  end

  defp print_answer(%{answer: response}) do
    message = Map.fetch!(response, :message)
    content = Map.get(message, :content, [])

    Enum.each(content, fn
      %{type: :text, text: text} ->
        IO.puts(text)

      _block ->
        :ok
    end)
  end

  defp print_answer(result) do
    IO.inspect(result, label: "Agent result")
  end

  defp knowledge_base do
    [
      %{
        id: "hayata-architecture",
        content:
          "Hayata is an Erlang/OTP framework for building AI agents. " <>
            "Its architecture is based on agents, nodes, edges and decision policies. " <>
            "The agent coordinates node execution and controls the execution flow.",
        metadata: %{
          source: "hayata-documentation",
          topic: "architecture"
        }
      },
      %{
        id: "hayata-parallel-execution",
        content:
          "Hayata supports parallel node execution. An agent can dispatch multiple " <>
            "nodes through a parallel transition. Each node executes independently " <>
            "and its result is collected in parallel_results in the requested order.",
        metadata: %{
          source: "hayata-documentation",
          topic: "parallel-execution"
        }
      },
      %{
        id: "hayata-rag",
        content:
          "Hayata provides provider-agnostic RAG retrieval through hayata_rag. " <>
            "Applications supply their own retriever function or MFA. Retrieved " <>
            "documents are validated and normalized into a common document contract.",
        metadata: %{
          source: "hayata-documentation",
          topic: "rag"
        }
      },
      %{
        id: "hayata-llm-tools",
        content:
          "Hayata integrates language models through hayata_llm and supports tool " <>
            "calling through hayata_tool_loop. The tool loop executes registered " <>
            "handlers, adds their results to the conversation and calls the model again.",
        metadata: %{
          source: "hayata-documentation",
          topic: "llm-tools"
        }
      },
      %{
        id: "hayata-checkpoints",
        content:
          "Hayata supports execution checkpoints and recovery. Checkpoints allow " <>
            "the framework to persist execution information and recover interrupted " <>
            "node executions.",
        metadata: %{
          source: "hayata-documentation",
          topic: "recovery"
        }
      }
    ]
  end

  defp query_tokens(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]]+/u, trim: true)
    |> Enum.filter(fn token -> String.length(token) >= 3 end)
    |> Enum.uniq()
  end

  defp relevance_score(tokens, content) do
    normalized_content = String.downcase(content)

    Enum.count(tokens, fn token ->
      String.contains?(normalized_content, token)
    end)
  end
end
