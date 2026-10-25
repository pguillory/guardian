defmodule Guardian.Rules.Store do
  @moduledoc """
  Rule policy for where rule files live. The store is a `Guardian.ObjectStore`: an
  S3-compatible bucket (`Guardian.ObjectStore.S3`) or a local folder
  (`Guardian.Rules.Store.Local`), chosen by `Guardian.Rules.Config`. There is no index
  or manifest: listing the store is the index, each object one rule file
  (`<table>/<name>.gsql`), plus the write lock (`lock_key/0`, a
  `Guardian.ObjectStore.Lock`), which the loader ignores.

  Writes take the lock with `lock_lease_ms/0` and save only with `save_margin_ms/0`
  of the lease left (`Guardian.Rules.Server`).
  """

  @lock_key "_write.lock"
  @lock_lease_ms 120_000
  # Well over the 20 s deadline `Guardian.ObjectStore.S3` puts on the one write a
  # holder makes, so a save that completes lands inside the lease. Raise it with that
  # deadline.
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

  def local?({Guardian.Rules.Store.Local, _config}) do
    true
  end

  def local?(_store) do
    false
  end
end
