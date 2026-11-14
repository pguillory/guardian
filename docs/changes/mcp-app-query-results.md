# mcp-app-query-results: a results table for MCP App hosts

## Problem

The `query` tool returns its rows as one JSON text. Clients that implement MCP Apps
and can show richer results had nothing to show but that text.

## Change

The `query` tool gets an MCP App view, following the stable MCP Apps spec
(2026-01-26, `github.com/modelcontextprotocol/ext-apps`,
`specification/2026-01-26/apps.mdx`).

1. Only for clients that ask. A session whose client declared
   `capabilities.extensions["io.modelcontextprotocol/ui"]` with
   `text/html;profile=mcp-app` among its `mimeTypes` gets the view; the spec says
   servers SHOULD check this. Every other session's tools/list, resources/list and
   results are byte for byte what they were. Guardian stays on protocol 2025-03-26:
   the result's `_meta` exists in that version, and only a client that declared the
   extension ever sees the tool's `_meta`, which came later.
2. For such a session, the `query` tool carries `_meta.ui.resourceUri =
   "ui://guardian/query-results"`, every tool carries `_meta.ui.visibility:
   ["model"]` (the view calls no tools, so a host following the spec refuses any call
   from it), and that resource is listed and readable: a static HTML page
   (`text/html;profile=mcp-app`, `_meta.ui.prefersBorder: true`).
3. Each `query` result keeps its content exactly as for any other client (what the
   model reads) and adds `_meta["guardian/html"]`: the SQL, a row count and a table
   of the rows in column-label order, rendered in Elixir by
   `Guardian.Web.MCP.ResultsView`. A failed query's result carries the SQL and the
   error message instead.
4. The page's one inline script does the MCP Apps handshake with the host over
   `postMessage` (`ui/initialize`, `ui/notifications/initialized`), applies the host's
   theme and CSS variables, swaps in the HTML from `ui/notifications/tool-result`,
   reports its size, and answers `ping` and `ui/resource-teardown`. It makes no
   network requests and calls no tools.
5. Limits on the view only: at most 300 rows and 100 KiB of row markup, whichever
   comes first, and the first 1,000 characters of each value, column label and error
   message (the SQL's first 2,000). When rows are left out it says "Showing N of M
   rows; the full result went to the model", or, when even the first row is over the
   budget, that it is too wide to show. Control characters other than tab and
   newlines, and invalid UTF-8, are shown as U+FFFD. The content is never cut.
6. Styling follows the old Guardian web UI (slate-blue header row, bordered cells,
   null in grey italics, numbers right-aligned in blue, true green, false red),
   adapted with `light-dark()` and the host's standard CSS variables so it follows the
   host's light or dark theme.

## Design notes

- Server-rendered, in the htmx manner but not with htmx. The spec has no slot for
  per-call HTML: a tool names one static template, which hosts may prefetch and
  cache, and the call's result reaches the page over `postMessage`. The page is
  sandboxed with `connect-src 'none'`, so it can't make the HTTP requests htmx is
  built on, and it must never hold Guardian's full-access key. So the server renders
  each result's HTML into the result's `_meta`, and a small script swaps it in, the
  way htmx swaps a fragment. Reversible: rendering in the browser from data, or
  fetching fragments through an app-only tool for paging, would both fit beside it.
- `_meta`, not `structuredContent`. The spec suggests `structuredContent` for view
  data, but Claude Code gives `structuredContent` to the model instead of the
  content, which would change what agents read, and 2025-03-26 has no such field.
  Hosts pass a result's `_meta` to the view and not to the model.
- Defense in depth against markup in event data. Values come from anyone holding
  either key, and a script in the page could ask the host to call Guardian's tools.
  Every value is escaped, and the page's own CSP allows only its own script, by a
  hash computed at compile time, so an escaping bug still couldn't run code. And
  every tool is marked visible to the model only, so a host following the spec would
  refuse a tool call from the view anyway (`docs/architecture/security.md` section
  4.7). A host that injects its own scripts
  into the page would be blocked too; whether any host does is not known.
- Tests parse the fragment with OTP's `:xmerl` (the fragment is kept well-formed
  XML), so no HTML parser dependency was added. FakeBrowser was considered: it drives
  a Plug over HTTP and runs no script, and the view gets its data over
  `postMessage`, so it had nothing to drive here.

## Product spec impact

`docs/product/spec.md` section 4.2 gains a paragraph before "Protocol version":

> Results view: a client that declares the MCP Apps extension
> (`io.modelcontextprotocol/ui`, with `text/html;profile=mcp-app` among its
> `mimeTypes`) in its `initialize` capabilities also gets a read-only table of `query`
> results, which App hosts show beside the result. For that session only, the `query`
> tool carries `_meta.ui.resourceUri` `ui://guardian/query-results`, every tool carries
> `_meta.ui.visibility: ["model"]` (the view may call none of them), that resource is
> listed and readable (a static HTML page), and each `query` result, success or tool
> error, carries `_meta["guardian/html"]`: the SQL and either a row count and a table
> of the rows in column order, or the error message. The table shows at most 300 rows
> and 100 KiB of row markup, and says when it shows fewer rows than the result has;
> values, column labels and the error message are cut at 1,000 characters, and the
> SQL at 2,000. The result's content, what the model reads, is
> the same as for any other client and is never cut. The view makes no requests and
> calls no tools. Every other client's tool list, resource list and results are
> unchanged.

Section 11 item 8. Before: "No web UI." After: "No web UI. MCP App hosts can show
`query` results as a table (section 4.2), but Guardian serves no web pages."

## Validation

- `test/guardian/web/mcp/results_view_test.exs`: the fragment's columns, rows and
  value types; hostile values, labels, SQL and errors come back as text with no
  element; the row (300 and 301), byte, value and SQL limits and their notes, a first
  row too wide to show; invalid UTF-8 and control characters; the page's CSP hash
  matches its script.
- `test/guardian/web/mcp/app_view_test.exs`, on the wire: a client declaring the
  extension gets the tool's `_meta.ui`, the listed and readable resource, and the
  HTML on a success and on an error, with the content unchanged, and every tool
  marked model-only. A 301-row result of 1,500-character values reaches the model
  whole while the view shows part of it. A plain client, and ones declaring the
  extension without the HTML type or with malformed settings, get no `_meta`, no
  resource, and results with only `content` and `isError`.
- By hand, once, in headless Chromium, with a throwaway host page that loads the view
  in a sandboxed frame: the handshake, `ping` and an unknown request answered, size
  reports after the handshake and after the swap, a 40-row table in the dark theme,
  and an `onerror` handler in swapped-in markup blocked by the page's CSP (the same
  markup runs once the CSP is removed).
