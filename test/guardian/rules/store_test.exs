defmodule Guardian.Rules.StoreTest do
  use ExUnit.Case, async: false

  test "the default save margin exceeds the S3 write deadline" do
    # TestEnv records prior values (or absence) and restores them on exit. Delete
    # these throwaway placeholders immediately so the defaults apply.
    Guardian.TestEnv.put(rules_save_margin_ms: 1, object_store_s3_write_deadline_ms: 1)
    Application.delete_env(:guardian, :rules_save_margin_ms)
    Application.delete_env(:guardian, :object_store_s3_write_deadline_ms)

    assert Guardian.Rules.Store.save_margin_ms() > Guardian.ObjectStore.S3.write_deadline_ms()
  end
end
