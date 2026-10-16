# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Nathan Kidd.

require "sus/fixtures/async/http/server_context"

require "async/firefly/client"

module Async
	module Firefly
		# Serves canned Firefly responses and records every request, because rule 11 establishes
		# conformance from what went on the wire rather than from the client's structure.
		ServerContext = Sus::Shared("a firefly server") do
			include Sus::Fixtures::Async::HTTP::ServerContext

			let(:requests) {[]}

			let(:responses) {{}}

			let(:app) do
				::Protocol::HTTP::Middleware.for do |request|
					path, query = request.path.split("?", 2)

					requests << {
						method: request.method,
						path: path,
						query: query && ::Protocol::URL::Encoding.decode(query, symbolize_keys: true),
						headers: request.headers.to_h,
						payload: request.body&.join,
					}

					status, body = responses.fetch([request.method, path]) do
						[404, {message: "no such route: #{path}"}]
					end

					::Protocol::HTTP::Response[status,
						{"content-type" => "application/vnd.api+json"},
						[::JSON.dump(body)]]
				end
			end

			let(:client) {Client.open("#{bound_url}/api/v1/").authenticated("test-token")}

			def respond(method, path, status: 200, body: {})
				responses[[method, path]] = [status, body]
			end

			after do
				@client&.close
			end
		end
	end
end
