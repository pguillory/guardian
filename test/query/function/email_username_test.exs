defmodule Guardian.Query.Function.EmailUsernameTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "email_username function" do
    assert eval("email_username('user@domain.com')") === "user"
  end
end
