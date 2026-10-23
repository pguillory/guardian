defmodule Rules.ConfigTest do
  use ExUnit.Case, async: true

  alias Rules.Config

  @s3 %{
    "GUARDIAN_RULES_S3_BUCKET" => "b",
    "GUARDIAN_RULES_S3_ENDPOINT" => "https://example.invalid",
    "GUARDIAN_RULES_S3_ACCESS_KEY_ID" => "id",
    "GUARDIAN_RULES_S3_SECRET_ACCESS_KEY" => "SECRET-XYZ",
  }

  test "defaults to a local folder under the data directory" do
    dir = Path.join(System.tmp_dir!(), "rules_config_#{System.unique_integer([:positive])}")

    assert {:ok, {Rules.Store.Local, %{dir: ^dir}}} =
             Config.from_env(%{"GUARDIAN_RULES_DIR" => dir})

    File.rm_rf!(dir)

    default = Path.join(Application.fetch_env!(:guardian, :data_dir), "rules")
    assert {:ok, {Rules.Store.Local, %{dir: ^default}}} = Config.from_env(%{})
  end

  test "an S3 store holds its secret only in a closure" do
    assert {:ok, {Rules.Store.S3, config}} = Config.from_env(@s3)
    assert config.region == "auto" and config.prefix == ""
    assert config.credentials.() == {"id", "SECRET-XYZ"}
    refute inspect(config) =~ "SECRET-XYZ"
    refute inspect(config, structs: false) =~ "SECRET-XYZ"
  end

  test "refuses partial, mixed or malformed settings" do
    assert Config.from_env(Map.delete(@s3, "GUARDIAN_RULES_S3_SECRET_ACCESS_KEY")) ==
             {:error, "rule store settings missing: GUARDIAN_RULES_S3_SECRET_ACCESS_KEY"}

    assert {:error, "set either GUARDIAN_RULES_DIR or" <> _} =
             Config.from_env(Map.put(@s3, "GUARDIAN_RULES_DIR", "/tmp/x"))

    assert {:error, "GUARDIAN_RULES_S3_REGION set without GUARDIAN_RULES_S3_BUCKET"} =
             Config.from_env(%{"GUARDIAN_RULES_S3_REGION" => "auto"})

    assert {:error, "GUARDIAN_RULES_S3_ENDPOINT must be" <> _} =
             Config.from_env(Map.put(@s3, "GUARDIAN_RULES_S3_ENDPOINT", "example.com"))

    assert {:error, "GUARDIAN_RULES_S3_PREFIX must end in /"} =
             Config.from_env(Map.put(@s3, "GUARDIAN_RULES_S3_PREFIX", "rules"))

    assert {:error, "GUARDIAN_RULES_S3_PREFIX may use only " <> _} =
             Config.from_env(Map.put(@s3, "GUARDIAN_RULES_S3_PREFIX", "my rules/"))
  end
end
