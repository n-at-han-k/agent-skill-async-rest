# Recipes

Self-contained solutions to the problems that come up in most clients. Each one is
independent — read only what you need.

## Contents

- [Authentication: bearer token](#authentication-bearer-token)
- [Authentication: query parameter](#authentication-query-parameter)
- [Authentication: refreshing credentials](#authentication-refreshing-credentials)
- [Vendor media types](#vendor-media-types)
- [Page-number pagination](#page-number-pagination)
- [Cursor pagination](#cursor-pagination)
- [Streaming newline-delimited JSON](#streaming-newline-delimited-json)
- [Server-sent events](#server-sent-events)
- [Body-based rate limits](#body-based-rate-limits)
- [Rejecting unexpected content types](#rejecting-unexpected-content-types)
- [Bootstrapping a websocket from REST](#bootstrapping-a-websocket-from-rest)
- [Concurrent requests](#concurrent-requests)
- [Testing against a real local server](#testing-against-a-real-local-server)

## Authentication: bearer token

Derive a client that carries the header. Returning a new client rather than mutating means
an unauthenticated and an authenticated view can coexist over one connection.

```ruby
def authenticated(token)
	self.with(headers: {"authorization" => "Bearer #{token}"})
end
```

Set a `user-agent` at the same time — many APIs require one and reject requests without it.

## Authentication: query parameter

Some APIs want the credential in the query string. Parameters merge across derivations, so
adding it once is enough; every later `#with` keeps it.

```ruby
def authenticated(token)
	self.with(parameters: {token: token})
end
```

## Authentication: refreshing credentials

When a token expires you need to replace the header on an existing connection. Keep the
credential outside the resource and build the authenticated view on demand, rather than
caching a derived client for the process lifetime:

```ruby
class Client < Async::REST::Resource
	def initialize(*arguments, credentials: nil, **options)
		super(*arguments, **options)

		@credentials = credentials
	end

	# Re-derive per call so a refreshed token takes effect immediately:
	def session
		self.with(headers: {"authorization" => "Bearer #{@credentials.access_token}"})
	end

	def user(id)
		User.new(session.with(path: "users/#{id}"))
	end
end
```

If you override `#initialize`, remember `.with` calls `self.class.new(delegate, reference,
headers)` positionally — so either accept those three leading arguments, or override
`.with` as well to carry your extra state.

## Vendor media types

```ruby
class Wrapper < Async::REST::Wrapper::JSON
	VND = "application/vnd.example.v3+json"

	def initialize
		super(VND)
	end

	def parser_for(response)
		if content_type = response.headers["content-type"]
			if content_type.start_with?(VND) || content_type.start_with?("application/json")
				return Async::REST::Wrapper::JSON::Parser
			end
		end

		return super
	end
end
```

When an API accepts form-encoded requests but answers with a vendor JSON type, use
`Wrapper::Form` with your own map instead — the keys become `accept` headers:

```ruby
class Wrapper < Async::REST::Wrapper::Form
	def initialize
		super({"application/vnd.example.v3+json" => Async::REST::Wrapper::JSON::Parser})
	end
end
```

## Page-number pagination

Loop inside `#each`, stopping when a page comes back short. `Enumerable` then gives you
`map`, `take`, `find` and the rest for free, and `take(5)` stops fetching after the first
page because enumeration is lazy.

```ruby
class Repositories < Representation
	include Enumerable

	PER_PAGE = 50

	def each(page: 1, per_page: PER_PAGE, **parameters)
		return to_enum(:each, page: page, per_page: per_page, **parameters) unless block_given?

		while true
			resource = @resource.with(parameters: {page: page, per_page: per_page, **parameters})
			items = self.class.get(resource)

			records = Array(items.value)
			break if records.empty?

			records.each do |attributes|
				yield Repository.new(@resource.with(path: "../repos/#{attributes[:id]}"),
					value: attributes, metadata: items.metadata)
			end

			break if records.size < per_page

			page += 1
		end
	end
end
```

## Cursor pagination

Same shape, but the next request's parameters come out of the previous response. Stop when
the cursor is absent rather than when the page is short, because cursor APIs often return a
full page with no successor.

```ruby
class Events < Representation
	include Enumerable

	def each(limit: 100)
		return to_enum(:each, limit: limit) unless block_given?

		cursor = nil

		while true
			parameters = {limit: limit}
			parameters[:after] = cursor if cursor

			page = self.class.get(@resource.with(parameters: parameters))
			value = page.value

			Array(value[:data]).each do |attributes|
				yield Event.new(@resource.with(path: "../events/#{attributes[:id]}"),
					value: attributes, metadata: page.metadata)
			end

			cursor = value.dig(:pagination, :next_cursor)
			break unless cursor
		end
	end
end
```

## Streaming newline-delimited JSON

The parser buffers bytes, emits one parsed object per line from `#read`, and accumulates a
final aggregate so the representation still has a sensible `#value` after the stream ends.
`#join` drives `#each` to completion and returns that aggregate.

```ruby
class StreamingParser < ::Protocol::HTTP::Body::Wrapper
	def initialize(...)
		super

		@buffer = String.new.b
		@offset = 0
		@value = {}
	end

	def read
		return if @buffer.nil?

		while true
			if index = @buffer.index("\n", @offset)
				line = @buffer.byteslice(@offset, index - @offset)
				@buffer = @buffer.byteslice(index + 1, @buffer.bytesize - index - 1)
				@offset = 0

				return ::JSON.parse(line, symbolize_names: true)
			end

			if chunk = super
				@buffer << chunk
			else
				return nil if @buffer.empty?

				line = @buffer
				@buffer = nil
				@offset = 0

				return ::JSON.parse(line, symbolize_names: true)
			end
		end
	end

	def join
		self.each{}

		return @value
	end
end
```

Subclass it per endpoint to choose what the stream folds into — that is how one transport
serves several endpoints whose chunks mean different things:

```ruby
class TokenParser < StreamingParser
	def initialize(...)
		super

		@text = String.new
		@value[:text] = @text
	end

	def each
		super do |line|
			token = line.delete(:token)
			@text << token.to_s
			@value.merge!(line)

			yield token
		end
	end
end
```

Then the endpoint picks the fold by picking a wrapper, and the caller gets both the live
stream and the final value from one pass:

```ruby
class Wrapper < Async::REST::Wrapper::Generic
	def prepare_request(request, payload)
		request.headers.add("accept", "application/json")
		request.headers.add("accept", "application/x-ndjson")

		if payload
			request.headers["content-type"] = "application/json"
			request.body = ::Protocol::HTTP::Body::Buffered.new([::JSON.dump(payload)])
		end
	end

	def parser_for(response)
		media_type, _ = response.headers["content-type"].split(";")

		case media_type
		when "application/json" then Async::REST::Wrapper::JSON::Parser
		when "application/x-ndjson" then TokenParser
		end
	end
end

# In the client — the block streams, the return value is the completed representation:
def complete(prompt, **options, &block)
	Completion.post(self.with(path: "completions"), {prompt: prompt, **options}) do |resource, response|
		yield response if block_given?

		Completion.new(resource, value: response.read, metadata: response.headers)
	end
end
```

`response.read` after the block has drained the body returns the accumulated `@value`,
because `#join` returns the aggregate rather than re-reading the socket.

## Server-sent events

`text/event-stream` frames are `data: …` lines separated by blank lines. Same structure as
NDJSON, different framing:

```ruby
class EventStreamParser < ::Protocol::HTTP::Body::Wrapper
	def initialize(...)
		super

		@buffer = String.new.b
		@events = []
		@value = {events: @events}
	end

	def read
		while true
			if index = @buffer.index("\n\n")
				frame = @buffer.byteslice(0, index)
				@buffer = @buffer.byteslice(index + 2, @buffer.bytesize - index - 2)

				data = frame.lines.filter_map do |line|
					line.delete_prefix("data:").strip if line.start_with?("data:")
				end.join("\n")

				next if data.empty? || data == "[DONE]"

				event = ::JSON.parse(data, symbolize_names: true)
				@events << event

				return event
			end

			chunk = super or return nil
			@buffer << chunk
		end
	end

	def join
		self.each{}

		return @value
	end
end
```

## Body-based rate limits

There is no verified recipe for this. What is known is that the obvious one is wrong: a retry
loop in `Wrapper#response_for` re-enters `Resource#call`, which rewrites the request in place,
so the second attempt goes out with the query string applied twice:

```
--> GET /v1/tasks?token=secret
--> GET /v1/tasks?token=secret?token=secret
```

Rule 37 forbids retrying there. A `429` with a plain `retry-after` header is already handled
by `Wrapper::Generic#response_for`, so check whether you need anything at all first.

## Rejecting unexpected content types

`process_response` is the place to assert what you'll accept, so a proxy's HTML error page
fails with a clear message instead of a `JSON::ParserError` from deep inside a parser.

```ruby
def process_response(request, response)
	if content_type = response.headers["content-type"]
		unless content_type.start_with?(@content_type)
			raise Async::Example::Error, "Unexpected content type: #{content_type}!"
		end
	end

	super
end
```

## Bootstrapping a websocket from REST

A common pattern: one REST call returns the socket URL, then the real work happens over the
websocket. Model the REST half as a representation whose only job is to hand over the URL.

```ruby
class Gateway < Representation
	def url
		self.value[:url]
	end

	def connect(&block)
		endpoint = Async::HTTP::Endpoint.parse(self.url,
			alpn_protocols: Async::HTTP::Protocol::HTTP11.names)

		Async::WebSocket::Client.connect(endpoint, handler: Connection, &block)
	end
end
```

Pin `alpn_protocols` to HTTP/1.1 — websockets over HTTP/2 need explicit support that many
servers lack, and negotiation silently picking h2 is a confusing failure. Keep protocol
state (heartbeats, sequence numbers, reconnection) in the `Async::WebSocket::Connection`
subclass, and make sure its `#close` stops any task it started.

## Concurrent requests

The connection is multiplexed, so fan out with `Async` and the requests overlap. Collect
tasks first, then wait — otherwise you serialise accidentally.

```ruby
Async::Example::Client.open do |client|
	tasks = ids.map do |id|
		Async{client.user(id).name}
	end

	names = tasks.map(&:wait)
end
```

Over HTTP/2 these share one connection. Over HTTP/1.1 the client pools connections, so
either way you don't manage sockets yourself. Add a `Async::Semaphore` if the API's
concurrency limit is lower than your fan-out.

## Testing against a real local server

`sus-fixtures-async-http` starts a real server on an ephemeral port, so tests exercise
genuine HTTP without touching the network. Assert on the request the client sent, which is
where client bugs actually live.

```ruby
require "sus/fixtures/async/http/server_context"
require "async/example/client"

describe Async::Example::Client do
	include Sus::Fixtures::Async::HTTP::ServerContext

	let(:requests) {[]}

	let(:app) do
		Protocol::HTTP::Middleware.for do |request|
			requests << {path: request.path, headers: request.headers.to_h}

			Protocol::HTTP::Response[200,
				{"content-type" => "application/json"},
				[JSON.dump({id: 1, name: "Test User"})]
			]
		end
	end

	let(:client) {Async::Example::Client.open(bound_url)}

	it "requests the versioned path and accepts JSON" do
		expect(client.user("test").name).to be == "Test User"

		expect(requests.first[:path]).to be == "/users/test"
		expect(requests.first[:headers]["accept"]).to be == "application/json"
	ensure
		client.close
	end
end
```

Note that `bound_url` has no path, so a client whose `ENDPOINT` carries a version prefix
loses it under test. Either assert the paths relative to the bound URL as above, or pass
the prefix explicitly: `Client.open("#{bound_url}/v2/")`.

For an exploratory loop rather than a test suite, `scripts/stub_server.rb` serves canned
responses from a JSON file and logs every request.
