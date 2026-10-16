# Template — `async-firefly`

A complete gem, in the shape a new `async-rest` client should take. Copy the directory, rename
`firefly` throughout, and replace the endpoints.

It is a working client for the [Firefly III](https://docs.firefly-iii.org/) API, rewritten from
an implementation that bypassed `async-rest` entirely — it `require`d `async/rest/resource` and
then routed every call through a hand-rolled `JsonRest::Endpoint`, so nothing was a resource,
nothing was a representation, and `paged` flattened every page into one array of hashes.

## Layout

```
async-firefly.gemspec        depends on async-rest ~> 0.20
Gemfile                      sus, covered, rubocop
flake.nix                    devShell; prefers a sibling ../async-rest/lib checkout
.envrc                       use flake
config/sus.rb                coverage, optional
lib/async/firefly.rb         entry point
lib/async/firefly/
  version.rb
  error.rb                   Error, Failure (status + payload), Duplicate
  redacted.rb                masks tokens in #inspect
  wrapper.rb                 media type selection; exactly one request per call
  representation.rb          base: pattern matching, cacheable?, Firefly's data envelope
  about.rb                   a single-document endpoint
  accounts.rb                Account, AccountPage, Accounts
  transactions.rb            Transaction, TransactionPage, Transactions
  client.rb                  the resource, its entry points, writes and retry
fixtures/async/firefly/
  server_context.rb          a real server that records every request
test/async/firefly/
  client.rb
  accounts.rb
```

## Which rule each decision comes from

| File | Decision | Rule |
|---|---|---|
| `client.rb` | `Client < Async::REST::Resource` with `ENDPOINT` | 1, 4 |
| `client.rb` | `#authenticated` derives with `.with(headers:)` | 6 |
| `client.rb` | `#initialize` override adds the user-agent to every request | 4 |
| `client.rb` | reads return `Klass.new(resource)`; writes go through the block form | 17, 18 |
| `client.rb` | identifiers escaped with `Protocol::URL::Encoding.escape` | 10 |
| `client.rb` | relative paths; `/api/v1/` lives only in `ENDPOINT` | 7, 23 |
| `client.rb` | `#with_retry` retries in the client method, never in the wrapper | 20 |
| `client.rb` | `#failure_for` reads the status, then the body, to pick the error | 18, 19 |
| `wrapper.rb` | `#response_for` performs exactly one request | 21 |
| `wrapper.rb` | `#parser_for` selects on the declared media type | 13 |
| `representation.rb` | `deconstruct_keys` and `deconstruct` | 22 |
| `representation.rb` | `#cacheable?` reads the response's control data | 16 |
| `redacted.rb` | secrets masked in `#inspect` | 25 |
| `accounts.rb` | `AccountPage` is one response; `Accounts` is a plain class that walks pages | 26 |
| `accounts.rb` | children seeded with `value:`, so a page costs one request | 17 |
| `fixtures/` | conformance established by recording the requests, not by reading the classes | 11 |

## What the rewrite changed

| Before | After | Rule |
|---|---|---|
| `Client` was a plain class wrapping `JsonRest::Endpoint` | `Client < Async::REST::Resource` | 1 |
| `/api/v1/...` repeated in every method | once, in `ENDPOINT` | 7, 23 |
| `paged` concatenated all pages into one array of hashes | `AccountPage` per response, `Accounts` walks them | 26 |
| endpoints returned raw `[:data]` hashes | representations with accessors | 2, 7 |
| `translate` rescued, then matched a substring of the message | status first, payload second, from the response | 18, 19 |
| nothing could be consumed incrementally | the body stays a stream | 6 |
| `Duplicate` raised from a rescue wrapping every call | raised where the status is known | 18 |

## Running it

```bash
bundle lock && bundix        # generate gemset.nix, once
nix develop
bundle exec sus
```

`flake.nix` puts a sibling `../async-rest/lib` ahead of the installed gem on `RUBYLIB`, so the
library can be read and changed alongside the client that depends on it.
