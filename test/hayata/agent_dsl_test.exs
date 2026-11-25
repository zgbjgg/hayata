defmodule Hayata.AgentDSLTest do
  use ExUnit.Case, async: true

  defmodule TestAgent do
    use Hayata.Agent

    agent do
      id("dsl_test_agent")

      state(%{
        messages: []
      })

      node "answer" do
        context ->
          %{
            answer: "Hello from DSL",
            received_input: context.input
          }
      end

      decision do
        on_step 0 do
          next("answer", input: :input)
        end

        on_step 1 do
          finish(:state)
        end
      end

      max_steps(5)
      execution_timeout(5_000)
    end
  end

  defmodule ParallelTestAgent do
    use Hayata.Agent

    agent do
      id("dsl_parallel_test_agent")

      state(%{
        messages: []
      })

      node "research" do
        context ->
          %{
            research: "Research: #{context.input}"
          }
      end

      node "analysis" do
        context ->
          %{
            analysis: "Analysis: #{context.input}"
          }
      end

      decision do
        on_step 0 do
          parallel(["research", "analysis"], input: :input)
        end

        on_step 2 do
          finish(:parallel_results)
        end
      end

      max_steps(5)
      execution_timeout(5_000)
    end
  end

  defmodule ConfiguredTestAgent do
    use Hayata.Agent

    agent do
      id("configured_test_agent")

      llm(%{
        adapter: :test_adapter,
        model: "test-model"
      })

      conversation_memory(true)

      rag_config(%{
        retrieve: fn _query, _options ->
          {:ok, %{documents: []}}
        end
      })

      node "answer" do
        context ->
          %{answer: context.input}
      end

      decision do
        on_step 0 do
          next("answer", input: :input)
        end

        on_step 1 do
          finish(:state)
        end
      end
    end
  end

  defmodule ExplicitContextTestAgent do
    use Hayata.Agent

    agent do
      id("explicit_context_test_agent")

      node "answer" do
        context ->
          %{answer: context.input}
      end

      decision do
        on_step 0, context do
          next("answer", input: context.input)
        end

        on_step 1, context do
          finish(context.state)
        end
      end
    end
  end

  defmodule ExplicitNodeContextTestAgent do
    use Hayata.Agent

    agent do
      id("explicit_context_test_agent")

      node "answer", context do
        %{answer: context.input}
      end

      decision do
        on_step 0, context do
          next("answer", input: context.input)
        end

        on_step 1, context do
          finish(context.state)
        end
      end
    end
  end

  defmodule PatternMatchingDecisionTestAgent do
    use Hayata.Agent

    agent do
      id("pattern_matching_decision_test_agent")

      state(%{
        status: :pending
      })

      node "process", context do
        %{processed: context.input}
      end

      decision do
        on_step _, %{state: %{status: :pending}} = context do
          next("process", input: context.input)
        end

        on_step _, %{state: %{status: :completed}} = context do
          finish(context.state)
        end
      end
    end
  end

  test "generates the expected agent configuration" do
    config = TestAgent.config()

    assert config.id == "dsl_test_agent"
    assert config.state == %{messages: []}
    assert config.max_steps == 5
    assert config.execution_timeout == 5_000
    assert Map.has_key?(config.nodes, :answer)
    assert is_function(config.decision_policy, 1)
  end

  test "generates atom node identifiers" do
    config = TestAgent.config()

    assert Map.keys(config.nodes) == [:answer]
  end

  test "generates a working decision policy" do
    config = TestAgent.config()

    first_decision =
      config.decision_policy.(%{
        step: 0,
        input: "test input"
      })

    assert first_decision == {:next, :answer, "test input"}

    second_decision =
      config.decision_policy.(%{
        step: 1,
        state: %{answer: "done"}
      })

    assert second_decision == {:finish, %{answer: "done"}}
  end

  test "generates an OTP child specification" do
    child_spec = TestAgent.child_spec([])

    assert child_spec.id == "dsl_test_agent"
    assert child_spec.type == :supervisor
    assert child_spec.restart == :permanent
  end

  test "starts and executes an agent defined with the DSL" do
    {:ok, supervisor_pid} =
      Supervisor.start_link(
        [TestAgent],
        strategy: :one_for_one
      )

    [{_id, agent_sup_pid, :supervisor, _modules}] = Supervisor.which_children(supervisor_pid)

    assert {:ok, _invocation_id} = Hayata.Agent.run(agent_sup_pid, "DSL input")

    result = await_result(agent_sup_pid)

    assert result == %{
             answer: "Hello from DSL",
             received_input: "DSL input",
             messages: []
           }

    assert :ok == Supervisor.stop(supervisor_pid)
  end

  test "generates a parallel decision with ordered node identifiers" do
    config = ParallelTestAgent.config()

    decision =
      config.decision_policy.(%{
        step: 0,
        input: "test input"
      })

    assert decision == {
             :next,
             [:research, :analysis],
             "test input"
           }
  end

  test "starts and executes parallel nodes defined with the DSL" do
    {:ok, supervisor_pid} =
      Supervisor.start_link(
        [ParallelTestAgent],
        strategy: :one_for_one
      )

    [{_id, agent_sup_pid, :supervisor, _modules}] = Supervisor.which_children(supervisor_pid)

    assert {:ok, _invocation_id} = Hayata.Agent.run(agent_sup_pid, "DSL input")

    result = await_result(agent_sup_pid)

    assert result == [
             %{research: "Research: DSL input"},
             %{analysis: "Analysis: DSL input"}
           ]

    assert :ok == Supervisor.stop(supervisor_pid)
  end

  test "generates LLM configuration" do
    config = ConfiguredTestAgent.config()

    assert config.llm == %{
             adapter: :test_adapter,
             model: "test-model"
           }
  end

  test "generates conversation memory configuration" do
    config = ConfiguredTestAgent.config()

    assert config.conversation_memory
  end

  test "generates RAG configuration" do
    config = ConfiguredTestAgent.config()

    assert is_function(config.rag_config.retrieve, 2)
  end

  test "supports explicit context variables in decision steps" do
    config = ExplicitContextTestAgent.config()

    first_decision =
      config.decision_policy.(%{
        step: 0,
        input: "explicit input"
      })

    assert first_decision == {:next, :answer, "explicit input"}

    state = %{answer: "completed"}

    second_decision =
      config.decision_policy.(%{
        step: 1,
        state: state
      })

    assert second_decision == {:finish, state}
  end

  test "supports explicit context variables in node definitions" do
    config = ExplicitNodeContextTestAgent.config()

    node_result =
      config.nodes.answer.(%{
        input: "input from explicit context"
      })

    assert node_result == %{
             answer: "input from explicit context"
           }
  end

  test "supports pattern matching on the complete decision context" do
    config = PatternMatchingDecisionTestAgent.config()

    pending_decision =
      config.decision_policy.(%{
        step: 0,
        input: "work to process",
        state: %{status: :pending}
      })

    assert pending_decision == {
             :next,
             :process,
             "work to process"
           }

    completed_state = %{status: :completed}

    completed_decision =
      config.decision_policy.(%{
        step: 1,
        input: nil,
        state: completed_state
      })

    assert completed_decision == {:finish, completed_state}
  end

  test "supports matching a specific step and context pattern" do
    config = PatternMatchingDecisionTestAgent.config()

    decision =
      config.decision_policy.(%{
        step: 0,
        input: "test",
        state: %{status: :pending}
      })

    assert decision == {:next, :process, "test"}
  end

  defp await_result(agent_sup_pid, attempts \\ 20)

  defp await_result(agent_sup_pid, 0) do
    Hayata.Agent.result(agent_sup_pid)
  end

  defp await_result(agent_sup_pid, attempts) do
    case Hayata.Agent.result(agent_sup_pid) do
      {:ok, result} ->
        result

      {:error, _reason} ->
        Process.sleep(25)
        await_result(agent_sup_pid, attempts - 1)
    end
  end
end
