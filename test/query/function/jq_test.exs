defmodule Query.Function.JqTest do
  # Changes jq limits in the application environment, so not async.
  use Query.EvaluationTestCase, async: false
  import TestHelpers, only: [eventually: 1, run_sql: 1]

  @canary_name "GUARDIAN_JQ_LEAK_CANARY_8244"
  @canary_value "canary-value-0d8b7f"

  setup do
    saved = Application.get_all_env(:guardian) |> Keyword.take(jq_keys())
    on_exit(fn -> Enum.each(jq_keys(), &restore(&1, saved)) end)
    :ok
  end

  defp jq_keys do
    [
      :jq_time_limit_ms,
      :jq_max_row_output_bytes,
      :jq_max_output_bytes,
      :jq_memory_limit_bytes,
      :jq_max_workers,
    ]
  end

  defp restore(key, saved) do
    case Keyword.fetch(saved, key) do
      {:ok, value} -> Application.put_env(:guardian, key, value)
      :error -> Application.delete_env(:guardian, key)
    end
  end

  defp sql_string(text), do: "'" <> String.replace(text, "'", "''") <> "'"

  # Runs `program` and returns its result or the error message.
  defp jq_result(program, input \\ "null") do
    run_sql("SELECT jq(#{sql_string(program)}, #{sql_string(input)})")
  rescue
    error in Query.Error -> {:error, error.message}
  end

  test "jq function" do
    assert eval("jq('.a', '{\"a\":1}')") === [1]
  end

  test "returns every output, integers as integers, and objects as JSON text" do
    assert jq_result(".[]", ~s([1, 2.5, "a", null, true, [1]])) == [
             [[1, 2.5, "a", nil, true, [1]]],
           ]

    assert jq_result(". * 2", "1.5") == [[[3]]]
    assert jq_result(".", ~s({"a": {"b": 1}})) == [[[~s({"a":{"b":1}})]]]
    assert jq_result("empty") == [[[]]]
  end

  test "non-string arguments and invalid JSON input give null" do
    assert eval("jq('.', 'not json')") === nil
    assert eval("jq(1, '{}')") === nil
    assert eval("jq('.', 1)") === nil
  end

  test "a runtime error keeps the outputs before it" do
    assert jq_result("1, error(\"boom\"), 2") == [[[1]]]
    assert jq_result(".a.b", "[1]") == [[[]]]
  end

  test "a compile error fails the query with jq's message" do
    assert {:error, message} = jq_result("{")
    assert message =~ "jq compile error"
    assert message =~ "syntax error"
  end

  test "a long compile error cut inside a multibyte character is still valid UTF-8" do
    program = "\"x" <> String.duplicate("é", 600) <> "\" | missing"
    assert {:error, message} = jq_result(program)
    assert String.valid?(message)
    assert {:ok, _} = Jason.encode(message)
  end

  test "evaluates a column of inputs and a column of programs" do
    table = "jq_columns_#{System.unique_integer([:positive])}"

    Engine.ingest_events(table, [
      %{"n" => 1, "p" => ".a", "j" => ~s({"a": 1})},
      %{"n" => 2, "p" => ".a", "j" => ~s({"a": 2})},
      %{"n" => 3, "p" => ".b", "j" => ~s({"b": 3})},
      %{"n" => 4, "p" => ".a", "j" => "not json"},
      %{"n" => 5, "p" => 7, "j" => ~s({"a": 5})},
    ])

    assert run_sql("SELECT n, jq(p, j) FROM #{table} ORDER BY n") ==
             [[1, [1]], [2, [2]], [3, [3]], [4, nil], [5, nil]]

    assert run_sql("SELECT n, jq('.a', j) FROM #{table} ORDER BY n") ==
             [[1, [1]], [2, [2]], [3, [nil]], [4, nil], [5, [5]]]

    assert run_sql("SELECT count() FROM #{table} WHERE jq('.a', j) = [2]") == [[1]]
  end

  describe "environment" do
    setup do
      System.put_env(@canary_name, @canary_value)
      on_exit(fn -> System.delete_env(@canary_name) end)
    end

    test "no spelling reaches the process environment" do
      programs = [
        "$ENV",
        "env",
        "$ENV.#{@canary_name}",
        "env.#{@canary_name}",
        "$ENV[\"#{@canary_name}\"]",
        "$ENV | keys",
        "env | to_entries",
        "env | getpath([\"#{@canary_name}\"])",
        "[env | paths]",
        "env | tostring",
        "$ENV | tojson",
        "[$ENV[]]",
        "env as $e | $e",
        "def f: env; f",
        "{} | .a = $ENV",
        "$ENV | with_entries(.)",
        "[env, $ENV] | map(length)",
        "env | @base64",
        "$__loc__",
        "input_filename",
        "get_search_list",
        "get_jq_origin",
        "get_prog_origin",
        "$__prog_args",
        "input",
        "[inputs]",
        "input_line_number",
        "\"x\" | modulemeta",
        "env | debug",
        "env | stderr",
        "env | halt_error",
        "builtins | length",
      ]

      for program <- programs do
        result = jq_result(program)
        text = inspect(result, limit: :infinity, printable_limit: :infinity)
        refute text =~ @canary_name, "#{program} leaked the variable name"
        refute text =~ @canary_value, "#{program} leaked the variable value"
      end

      assert jq_result("$ENV") == [[["{}"]]]
      assert jq_result("env") == [[["{}"]]]
      assert jq_result("[env, $ENV] | map(length)") == [[[[0, 0]]]]
    end
  end

  describe "files" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "guardian_jq_files_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "secret.json"), ~s({"secret": "#{@canary_value}"}))
      File.write!(Path.join(dir, "lib.jq"), ~s(def leak: "#{@canary_value}";))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "modules and data files cannot be read", %{dir: dir} do
      programs = [
        ~s(import "secret" as $s {search: "#{dir}"}; $s),
        ~s(import "secret" as $s {search: ["#{dir}"]}; $s::s),
        ~s(include "lib" {search: "#{dir}"}; leak),
        ~s(import "lib" as l {search: "#{dir}"}; l::leak),
        ~s(import "#{Path.basename(dir)}/secret" as $s {search: "#{Path.dirname(dir)}"}; $s),
      ]

      for program <- programs do
        result = jq_result(program)
        refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ @canary_value
        assert {:error, _message} = result, "#{program} did not fail: #{inspect(result)}"
      end

      # modulemeta reads module files too; it fails at run time, giving no outputs.
      assert jq_result(~s("lib" | modulemeta)) == [[[]]]
    end
  end

  describe "limits" do
    test "a program that never finishes ends with a time-limit error" do
      Application.put_env(:guardian, :jq_time_limit_ms, 500)

      for program <- ["last(range(1e18))", "until(false; .)", "[limit(1e18; repeat(empty))]"] do
        {elapsed, result} = :timer.tc(fn -> jq_result(program) end, :millisecond)
        assert {:error, message} = result
        assert message =~ "time limit (500 ms)", "#{program}: #{message}"
        assert elapsed < 3_000, "#{program} took #{elapsed} ms"
      end
    end

    test "a time limit over a table fails the query once, well within the stage timeout" do
      Application.put_env(:guardian, :jq_time_limit_ms, 500)
      table = "jq_runaway_#{System.unique_integer([:positive])}"
      Engine.ingest_events(table, Enum.map(1..20, &%{"j" => "#{&1}"}))

      {elapsed, error} =
        :timer.tc(
          fn ->
            assert_raise Query.Error, fn ->
              run_sql("SELECT jq('last(range(1e18))', j) FROM #{table}")
            end
          end,
          :millisecond
        )

      assert error.message =~ "time limit"
      assert elapsed < 4_000
    end

    test "endless output ends with an output-limit error" do
      Application.put_env(:guardian, :jq_max_row_output_bytes, 10_000)
      assert {:error, message} = jq_result("repeat(1)")
      assert message =~ "jq output for one row exceeds 10000 bytes"

      assert {:error, message} = jq_result("[range(10000)]")
      assert message =~ "exceeds 10000 bytes"

      Application.put_env(:guardian, :jq_max_row_output_bytes, 1024 * 1024)
      Application.put_env(:guardian, :jq_max_output_bytes, 20_000)
      table = "jq_total_output_#{System.unique_integer([:positive])}"
      Engine.ingest_events(table, Enum.map(1..50, &%{"j" => "#{&1}"}))

      error =
        assert_raise Query.Error, fn -> run_sql("SELECT jq('[range(1000)]', j) FROM #{table}") end

      assert error.message =~ "jq output exceeds 20000 bytes"
    end

    test "output limits count each row's whole JSON array, empty ones included" do
      table = "jq_empty_output_#{System.unique_integer([:positive])}"
      Engine.ingest_events(table, Enum.map(1..10, &%{"j" => "#{&1}"}))

      # Ten empty results are 20 bytes of "[]".
      Application.put_env(:guardian, :jq_max_output_bytes, 19)
      error = assert_raise Query.Error, fn -> run_sql("SELECT jq('empty', j) FROM #{table}") end
      assert error.message =~ "jq output exceeds 19 bytes"

      Application.put_env(:guardian, :jq_max_output_bytes, 20)
      assert length(run_sql("SELECT jq('empty', j) FROM #{table}")) == 10

      Application.put_env(:guardian, :jq_max_row_output_bytes, 2)
      assert jq_result("empty") == [[[]]]
      assert {:error, message} = jq_result("1")
      assert message =~ "jq output for one row exceeds 2 bytes"
    end

    test "an input over the worker's 8 MiB request limit fails with a clear error" do
      input = String.duplicate("a", 8 * 1024 * 1024)

      error = assert_raise Query.Error, fn -> Query.Jq.eval_rows([{".", input}]) end
      assert error.message =~ "jq input is 8388608 bytes"

      error = assert_raise Query.Error, fn -> Query.Jq.eval_rows([{input, "1"}]) end
      assert error.message =~ "jq program is 8388608 bytes"
    end

    @tag :linux
    test "a program that allocates without bound ends with a memory-limit error" do
      Application.put_env(:guardian, :jq_memory_limit_bytes, 128 * 1024 * 1024)
      Application.put_env(:guardian, :jq_time_limit_ms, 4_000)

      for program <- [
            "[range(1e10)]",
            "\"x\" * 1e10",
            "def f: [f]; f",
            "reduce range(1e10) as $i (\"\"; . + \"xxxxxxxx\")",
          ] do
        assert {:error, message} = jq_result(program)
        assert message =~ "memory limit" or message =~ "time limit", "#{program}: #{message}"
      end
    end

    test "concurrent workers are limited per machine" do
      saved = Application.get_all_env(:guardian) |> Keyword.take([:jq_time_limit_ms])
      Application.put_env(:guardian, :jq_max_workers, 1)
      # Short, so the busy query gives up waiting for a slot quickly.
      Application.put_env(:guardian, :jq_time_limit_ms, 300)

      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, _slot} = Query.Jq.Slots.acquire(1_000)
          send(test_pid, :holding)
          Process.sleep(:infinity)
        end)

      assert_receive :holding
      assert {:error, message} = jq_result(".")
      assert message =~ "jq is busy"

      Process.exit(holder, :kill)
      eventually(fn -> Query.Jq.Slots.held() == 0 end)
      # The limit also bounds a worker's whole life, which a loaded host can take
      # longer than 300 ms to start.
      restore(:jq_time_limit_ms, saved)
      assert jq_result(".", "1") == [[[1]]]
      # The worker's slot is released with a cast, so it may land after the result.
      eventually(fn -> Query.Jq.Slots.held() == 0 end)
    end
  end
end
