defmodule Guardian.Rules.ConfigTest do
  use ExUnit.Case, async: true
  import Guardian.Rules.Config

  @s3 %{
    "GUARDIAN_RULES_S3_BUCKET" => "b",
    "GUARDIAN_RULES_S3_ENDPOINT" => "https://example.invalid",
    "GUARDIAN_RULES_S3_ACCESS_KEY_ID" => "id",
    "GUARDIAN_RULES_S3_SECRET_ACCESS_KEY" => "SECRET-XYZ",
  }

  test "defaults to a local folder under the data directory" do
    dir = Path.join(System.tmp_dir!(), "rules_config_#{System.unique_integer([:positive])}")

    assert {:ok, {Guardian.ObjectStore.Local, %{dir: ^dir}}} =
             from_env(%{"GUARDIAN_RULES_DIR" => dir})

    File.rm_rf!(dir)

    default = Path.join(Application.fetch_env!(:guardian, :data_dir), "rules")
    assert {:ok, {Guardian.ObjectStore.Local, %{dir: ^default}}} = from_env(%{})
  end

  test "refuses a rule folder that is or contains the data folder, or is in its segments" do
    data_dir = Application.fetch_env!(:guardian, :data_dir)
    message = "GUARDIAN_RULES_DIR must not be the data folder or a folder containing it"

    for dir <- [data_dir, data_dir <> "/", Path.dirname(data_dir), Path.join(data_dir, "..")] do
      assert from_env(%{"GUARDIAN_RULES_DIR" => dir}) == {:error, message}
    end

    assert from_env(%{"GUARDIAN_RULES_DIR" => Path.join(data_dir, "segments/x")}) ==
             {:error, "GUARDIAN_RULES_DIR must not be inside the segments folder"}

    # A sibling whose name starts with the data folder's is not inside it.
    sibling = data_dir <> "_rules_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(sibling) end)
    assert {:ok, _store} = from_env(%{"GUARDIAN_RULES_DIR" => sibling})
  end

  test "an S3 store takes its settings from the environment" do
    assert {:ok, {Guardian.ObjectStore.S3, config}} = from_env(@s3)
    assert config.region == "auto" and config.prefix == ""
    assert config.access_key_id == "id" and config.secret_access_key == "SECRET-XYZ"
  end

  test "refuses partial, mixed or malformed settings" do
    assert from_env(Map.delete(@s3, "GUARDIAN_RULES_S3_SECRET_ACCESS_KEY")) ==
             {:error, "rule store settings missing: GUARDIAN_RULES_S3_SECRET_ACCESS_KEY"}

    assert {:error, "set either GUARDIAN_RULES_DIR or" <> _} =
             from_env(Map.put(@s3, "GUARDIAN_RULES_DIR", "/tmp/x"))

    assert {:error, "GUARDIAN_RULES_S3_REGION set without GUARDIAN_RULES_S3_BUCKET"} =
             from_env(%{"GUARDIAN_RULES_S3_REGION" => "auto"})

    assert {:error, "GUARDIAN_RULES_S3_ENDPOINT must be" <> _} =
             from_env(Map.put(@s3, "GUARDIAN_RULES_S3_ENDPOINT", "example.com"))

    assert {:error, "GUARDIAN_RULES_S3_PREFIX must end in /"} =
             from_env(Map.put(@s3, "GUARDIAN_RULES_S3_PREFIX", "rules"))

    assert {:error, "GUARDIAN_RULES_S3_PREFIX may use only " <> _} =
             from_env(Map.put(@s3, "GUARDIAN_RULES_S3_PREFIX", "my rules/"))
  end

  test "http:// only for a server on this machine" do
    endpoint = &from_env(Map.put(@s3, "GUARDIAN_RULES_S3_ENDPOINT", &1))

    for url <- [
          "http://localhost:9000",
          "http://127.0.0.1:9000",
          "http://127.0.0.2",
          "http://[::1]:9000",
          "https://127.evil.example",
        ] do
      assert {:ok, {Guardian.ObjectStore.S3, %{endpoint: ^url}}} = endpoint.(url)
    end

    for url <- [
          "http://example.com",
          "http://127.evil.example",
          "http://localhost.example",
          "http://[::ffff:127.0.0.1]",
          "http://10.0.0.1",
          "http://127.1",
          # A lenient parse reads this as octal: 87.0.0.1.
          "http://0127.0.0.1",
          "HTTP://example.com",
          "http://localhost@evil.example",
          "http://localhost.",
        ] do
      assert {:error, "GUARDIAN_RULES_S3_ENDPOINT must use https://" <> _} = endpoint.(url)
    end
  end
end
