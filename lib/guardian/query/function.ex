defmodule Guardian.Query.Function do
  @names_and_mods [
    {"abs", 1, Guardian.Query.Function.Abs},
    {"adddate", 2, Guardian.Query.Function.DateAdd},
    {"ceil", 1, Guardian.Query.Function.Ceil},
    {"coalesce", 1, Guardian.Query.Function.Coalesce},
    {"coalesce", 2, Guardian.Query.Function.Coalesce},
    {"coalesce", 3, Guardian.Query.Function.Coalesce},
    {"coalesce", 4, Guardian.Query.Function.Coalesce},
    {"concat", 2, Guardian.Query.Function.Concat},
    {"concat", 3, Guardian.Query.Function.Concat},
    {"concat", 4, Guardian.Query.Function.Concat},
    {"concat", 5, Guardian.Query.Function.Concat},
    {"concat", 6, Guardian.Query.Function.Concat},
    {"concat", 7, Guardian.Query.Function.Concat},
    {"concat", 8, Guardian.Query.Function.Concat},
    {"concat", 9, Guardian.Query.Function.Concat},
    {"cosine_similarity", 2, Guardian.Query.Function.CosineSimilarity},
    {"curdate", 0, Guardian.Query.Function.Date},
    {"current_date", 0, Guardian.Query.Function.Date},
    {"current_timestamp", 0, Guardian.Query.Function.Now},
    {"date", 0, Guardian.Query.Function.Date},
    {"date", 1, Guardian.Query.Function.Date},
    {"date_add", 2, Guardian.Query.Function.DateAdd},
    {"date_sub", 2, Guardian.Query.Function.DateSub},
    {"div", 2, Guardian.Query.Function.Div},
    {"email_username", 1, Guardian.Query.Function.EmailUsername},
    {"email_domain", 1, Guardian.Query.Function.EmailDomain},
    {"exp", 1, Guardian.Query.Function.Exp},
    {"factorial", 1, Guardian.Query.Function.Factorial},
    {"floor", 1, Guardian.Query.Function.Floor},
    {"format_timestamp", 2, Guardian.Query.Function.FormatTimestamp},
    {"generate_uuid", 0, Guardian.Query.Function.GenerateUUID},
    {"if", 2, Guardian.Query.Function.If},
    {"if", 3, Guardian.Query.Function.If},
    {"interval", 1, Guardian.Query.Function.Interval},
    {"ip_to_integer", 1, Guardian.Query.Function.IpToInteger},
    {"length", 1, Guardian.Query.Function.Length},
    {"log", 1, Guardian.Query.Function.Log},
    {"log10", 1, Guardian.Query.Function.Log10},
    {"log2", 1, Guardian.Query.Function.Log2},
    {"lower", 1, Guardian.Query.Function.Lower},
    {"lpad", 2, Guardian.Query.Function.Lpad},
    {"ltrim", 1, Guardian.Query.Function.Ltrim},
    {"md5", 1, Guardian.Query.Function.Md5},
    {"mod", 2, Guardian.Query.Function.Mod},
    {"normalize", 1, Guardian.Query.Function.Normalize},
    {"normalize", 2, Guardian.Query.Function.Normalize},
    {"now", 0, Guardian.Query.Function.Now},
    {"pi", 0, Guardian.Query.Function.Pi},
    {"power", 2, Guardian.Query.Function.Power},
    {"random", 0, Guardian.Query.Function.Random},
    {"random", 1, Guardian.Query.Function.Random},
    {"replace", 3, Guardian.Query.Function.Replace},
    {"reverse", 1, Guardian.Query.Function.Reverse},
    {"round", 1, Guardian.Query.Function.Round},
    {"rpad", 2, Guardian.Query.Function.Rpad},
    {"rtrim", 1, Guardian.Query.Function.Rtrim},
    {"sha1", 1, Guardian.Query.Function.Sha1},
    {"sha256", 1, Guardian.Query.Function.Sha256},
    {"sha512", 1, Guardian.Query.Function.Sha512},
    {"sqrt", 1, Guardian.Query.Function.Sqrt},
    {"subdate", 2, Guardian.Query.Function.DateSub},
    {"substr", 2, Guardian.Query.Function.Substr},
    {"substr", 3, Guardian.Query.Function.Substr},
    {"to_boolean", 1, Guardian.Query.Function.ToBoolean},
    {"to_seconds", 1, Guardian.Query.Function.ToSeconds},
    {"to_string", 1, Guardian.Query.Function.ToString},
    {"trim", 1, Guardian.Query.Function.Trim},
    {"type", 1, Guardian.Query.Function.Type},
    {"unix_timestamp", 1, Guardian.Query.Function.ToSeconds},
    {"upper", 1, Guardian.Query.Function.Upper},
    {"url_fragment", 1, Guardian.Query.Function.UrlFragment},
    {"url_host", 1, Guardian.Query.Function.UrlHost},
    {"url_path", 1, Guardian.Query.Function.UrlPath},
    {"url_port", 1, Guardian.Query.Function.UrlPort},
    {"url_scheme", 1, Guardian.Query.Function.UrlScheme},
  ]

  # Tests need an expression that raises while a worker evaluates it, and no real
  # function raises (they return null instead), so the test build adds one.
  if Mix.env() == :test do
    @names_and_mods @names_and_mods ++ [{"test_raise", 1, Guardian.Query.Function.TestRaise}]
  end

  {names, arities, mods} = SuperList.unzip(@names_and_mods)
  @names names
  @names_and_arities SuperList.zip(names, arities)
  @name_and_arity_to_mod SuperList.zip(@names_and_arities, mods) |> Map.new()

  def names do
    @names
  end

  def names_and_arities do
    @names_and_arities
  end

  def name_and_arity_to_mod(name, arity) do
    case Map.fetch(@name_and_arity_to_mod, {name, arity}) do
      {:ok, mod} ->
        {:ok, mod}

      :error ->
        {:error, :not_found}
    end
  end
end
