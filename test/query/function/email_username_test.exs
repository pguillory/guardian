defmodule Query.Function.EmailUsernameTest do
  use Query.EvaluationTestCase, async: true

  test "email_username function" do
    assert eval("email_username('user@domain.com')") === "user"
  end
end
