defmodule Guardian.Rules.Store do
  @moduledoc """
  Rule policy for where rule files live. The store is a `Guardian.ObjectStore`: an
  S3-compatible bucket (`Guardian.ObjectStore.S3`) or a local folder
  (`Guardian.ObjectStore.Local`), chosen by `Guardian.Rules.Config`. There is no index
  or manifest: listing the store is the index. Each `.gsql` object is a rule file
  (`<table>/<name>.gsql`, or a validation error at any other path,
  `Guardian.Rules.RuleSet.parse_key/1`); every other object, the write lock
  (`lock_key/0`, a `Guardian.ObjectStore.Lock`) among them, is ignored.

  Writes take the lock with `lock_lease_ms/0` and save only with `save_margin_ms/0`
  of the lease left (`Guardian.Rules.Server`).
  """

  @lock_key "_write.lock"
  @lock_lease_ms 120_000
  # Well over Guardian.ObjectStore.S3.write_deadline_ms/0 for the one S3 write a
  # holder makes, including time before the write starts. StoreTest checks that
  # dependency against the defaults; reconsider this margin when the deadline grows.
  @save_margin_ms 80_000

  @doc "The key of the rule write lock."
  def lock_key do
    @lock_key
  end

  # Tests shorten the lease and the margin through app env.
  @doc "The rule write lock's lease."
  def lock_lease_ms do
    Application.get_env(:guardian, :rules_lock_lease_ms, @lock_lease_ms)
  end

  @doc "How much of the lease must be left before the one write a holder makes."
  def save_margin_ms do
    Application.get_env(:guardian, :rules_save_margin_ms, @save_margin_ms)
  end

  def local?({Guardian.ObjectStore.Local, _config}) do
    true
  end

  def local?(_store) do
    false
  end
end
