defmodule Query.Function do
  @names_and_mods [
    {"abs", 1, Query.Function.Abs},
    {"adddate", 2, Query.Function.DateAdd},
    {"ceil", 1, Query.Function.Ceil},
    {"coalesce", 1, Query.Function.Coalesce},
    {"coalesce", 2, Query.Function.Coalesce},
    {"coalesce", 3, Query.Function.Coalesce},
    {"coalesce", 4, Query.Function.Coalesce},
    {"concat", 2, Query.Function.Concat},
    {"concat", 3, Query.Function.Concat},
    {"concat", 4, Query.Function.Concat},
    {"concat", 5, Query.Function.Concat},
    {"concat", 6, Query.Function.Concat},
    {"concat", 7, Query.Function.Concat},
    {"concat", 8, Query.Function.Concat},
    {"concat", 9, Query.Function.Concat},
    {"cosine_similarity", 2, Query.Function.CosineSimilarity},
    {"curdate", 0, Query.Function.Date},
    {"current_date", 0, Query.Function.Date},
    {"current_timestamp", 0, Query.Function.Now},
    {"date", 0, Query.Function.Date},
    {"date", 1, Query.Function.Date},
    {"date_add", 2, Query.Function.DateAdd},
    {"date_sub", 2, Query.Function.DateSub},
    {"div", 2, Query.Function.Div},
    {"email_username", 1, Query.Function.EmailUsername},
    {"email_domain", 1, Query.Function.EmailDomain},
    {"exp", 1, Query.Function.Exp},
    {"factorial", 1, Query.Function.Factorial},
    {"floor", 1, Query.Function.Floor},
    {"format_timestamp", 2, Query.Function.FormatTimestamp},
    {"generate_uuid", 0, Query.Function.GenerateUUID},
    {"if", 2, Query.Function.If},
    {"if", 3, Query.Function.If},
    {"interval", 1, Query.Function.Interval},
    {"ip_to_integer", 1, Query.Function.IpToInteger},
    {"length", 1, Query.Function.Length},
    {"log", 1, Query.Function.Log},
    {"log10", 1, Query.Function.Log10},
    {"log2", 1, Query.Function.Log2},
    {"lower", 1, Query.Function.Lower},
    {"lpad", 2, Query.Function.Lpad},
    {"ltrim", 1, Query.Function.Ltrim},
    {"md5", 1, Query.Function.Md5},
    {"mod", 2, Query.Function.Mod},
    {"normalize", 1, Query.Function.Normalize},
    {"normalize", 2, Query.Function.Normalize},
    {"now", 0, Query.Function.Now},
    {"pi", 0, Query.Function.Pi},
    {"power", 2, Query.Function.Power},
    {"random", 0, Query.Function.Random},
    {"random", 1, Query.Function.Random},
    {"replace", 3, Query.Function.Replace},
    {"reverse", 1, Query.Function.Reverse},
    {"round", 1, Query.Function.Round},
    {"rpad", 2, Query.Function.Rpad},
    {"rtrim", 1, Query.Function.Rtrim},
    {"sha1", 1, Query.Function.Sha1},
    {"sha256", 1, Query.Function.Sha256},
    {"sha512", 1, Query.Function.Sha512},
    {"sqrt", 1, Query.Function.Sqrt},
    {"subdate", 2, Query.Function.DateSub},
    {"substr", 2, Query.Function.Substr},
    {"substr", 3, Query.Function.Substr},
    {"to_boolean", 1, Query.Function.ToBoolean},
    {"to_seconds", 1, Query.Function.ToSeconds},
    {"to_string", 1, Query.Function.ToString},
    {"trim", 1, Query.Function.Trim},
    {"type", 1, Query.Function.Type},
    {"unix_timestamp", 1, Query.Function.ToSeconds},
    {"upper", 1, Query.Function.Upper},
    {"url_fragment", 1, Query.Function.UrlFragment},
    {"url_host", 1, Query.Function.UrlHost},
    {"url_path", 1, Query.Function.UrlPath},
    {"url_port", 1, Query.Function.UrlPort},
    {"url_scheme", 1, Query.Function.UrlScheme},
  ]

  # Tests need an expression that raises while a worker evaluates it, and no real
  # function raises (they return null instead), so the test build adds one.
  if Mix.env() == :test do
    @names_and_mods @names_and_mods ++ [{"test_raise", 1, Query.Function.TestRaise}]
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
