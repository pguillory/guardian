defmodule Query.Function.EmailDomainTest do
  use Query.EvaluationTestCase, async: true

  test "email_domain function" do
    assert eval("email_domain('user@domain.com')") === "domain.com"
  end
end
