# Copyright 2016 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require "google/cloud/core/environment"
require "stackdriver/core/trace_context"

module Google
  module Cloud
    module Trace
      ##
      # A Rack middleware that manages trace context and captures a trace of
      # the request. Specifically, it:
      #
      # *   Reads the trace context from the request headers, if present.
      #     Otherwise, generates a new trace context.
      # *   Makes a sampling decision if one is not already specified.
      # *   Records a span measuring the entire handling of the request,
      #     annotated with a set of standard request data.
      # *   Makes the trace context available so downstream middlewares and the
      #     app can add further spans to the trace.
      # *   Sends the completed trace to the Stackdriver service.
      #
      # To use this middleware, simply install it in your middleware stack.
      # If your application uses Ruby On Rails, you may also use the provided
      # {Google::Cloud::Trace::Railtie} for close integration with Rails and
      # ActiveRecord.
      #
      # @example
      #   # config.ru for simple Rack application
      #
      #   require "google/cloud/trace"
      #   use Google::Cloud::Trace::Middleware
      #
      #   run MyApp
      #
      # @example
      #   # Simple sinatra application
      #
      #   require "sinatra"
      #   require "google/cloud/trace"
      #
      #   use Google::Cloud::Trace::Middleware
      #
      #   get "/" do
      #     "Hello World"
      #   end
      #
      class Middleware
        ##
        # Default list of paths for which to disable traces. Currently includes
        # App Engine Flex health checks.
        DEFAULT_PATH_BLACKLIST = ["/_ah/health"].freeze

        ##
        # The name of this trace agent as reported to the Stackdriver backend.
        AGENT_NAME = "ruby #{Google::Cloud::Trace::VERSION}".freeze

        ##
        # Create a new Middleware for traces
        #
        # @param [Rack Application] app Rack application
        # @param [Google::Cloud::Trace::Service] service The service object.
        #     Optional if running on GCE.
        # @param [Array{String,Regex}] path_blacklist An array of paths or
        #     path patterns indicating URIs that should never be traced.
        #     Default is DEFAULT_PATH_BLACKLIST.
        # @param [Boolean] capture_stack Whether to capture stack traces for
        #     each span. Default is false.
        # @param [#check] sampler A sampler to use, or nil to use the default.
        #     See {Google::Cloud::Trace.sampler=}
        #
        def initialize app,
                       service: nil,
                       path_blacklist: nil,
                       capture_stack: false,
                       sampler: nil,
                       span_id_generator: nil
          @app = app
          @path_blacklist = path_blacklist || DEFAULT_PATH_BLACKLIST
          @capture_stack = capture_stack
          @sampler = sampler
          @span_id_generator = span_id_generator
          if service
            @service = service
          else
            project_id = Google::Cloud::Trace::Project.default_project
            @service = Google::Cloud::Trace.new.service if project_id
          end
        end

        ##
        # Implementation of the trace middleware. Creates a trace for this
        # request, populates it with a root span for the entire request, and
        # ensures it is reported back to Stackdriver.
        #
        # @param [Hash] env Rack environment hash
        # @return [Rack::Response] The response from downstream Rack app
        #
        def call env
          trace = create_trace env
          begin
            Google::Cloud::Trace.set trace
            Google::Cloud::Trace.in_span "rack-request" do |span|
              configure_span span, env
              result = @app.call env
              configure_result span, result
              result
            end
          ensure
            Google::Cloud::Trace.set nil
            send_trace trace, env
          end
        end

        ##
        # Gets the current trace context from the given Rack environment.
        # Makes a sampling decision if one has not been made already.
        #
        # @private
        # @param [Hash] env Rack environment hash
        # @return [Stackdriver::Core::TraceContext] The trace context.
        #
        def get_trace_context env
          Stackdriver::Core::TraceContext.parse_rack_env(env) do |tc|
            if tc.sampled?.nil?
              path = get_path env
              if @path_blacklist.find { |p| p === path }
                sampled = false
              elsif @sampler
                sampled = @sampler.check {}
              else
                sampled = Google::Cloud::Trace.check_sampler
              end
              tc = Stackdriver::Core::TraceContext.new \
                trace_id: tc.trace_id,
                span_id: tc.span_id,
                sampled: sampled,
                capture_stack: sampled && @capture_stack
            end
            tc
          end
        end

        ##
        # Create a new trace for this request.
        #
        # @private
        # @param [Hash] env The Rack environment.
        #
        def create_trace env
          trace_context = get_trace_context env

          # TEMP: Drop the context parent span because a bug is preventing
          # such traces from appearing in Flex apps. We expect this bug to
          # be fixed around 2016.12.16, so re-check around that time.
          trace_context = trace_context.with span_id: nil

          Google::Cloud::Trace::TraceRecord.new \
            @service.project,
            trace_context,
            span_id_generator: @span_id_generator
        end

        ##
        # Send the given trace to the trace service, if requested.
        #
        # @private
        # @param [Google::Cloud::Trace::TraceRecord] trace The trace to send.
        # @param [Hash] env The Rack environment.
        #
        def send_trace trace, env
          if @service && trace.trace_context.sampled?
            begin
              @service.patch_traces trace
            rescue => ex
              msg = "Transmit to Stackdriver Trace failed: #{ex.inspect}"
              logger = env["rack.logger"]
              if logger
                logger.error msg
              else
                warn msg
              end
            end
          end
        end

        ##
        # Gets the URI path from the given Rack environment.
        #
        # @private
        # @param [Hash] env Rack environment hash
        # @return [String] The URI path.
        #
        def get_path env
          path = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
          path = "/#{path}" unless path.start_with? "/"
          path
        end

        ##
        # Gets the URI hostname from the given Rack environment.
        #
        # @private
        # @param [Hash] env Rack environment hash
        # @return [String] The hostname.
        #
        def get_host env
          env["HTTP_HOST"] || env["SERVER_NAME"]
        end

        ##
        # Gets the full URL from the given Rack environment.
        #
        # @private
        # @param [Hash] env Rack environment hash
        # @return [String] The URL.
        #
        def get_url env
          path = get_path env
          host = get_host env
          scheme = env["rack.url_scheme"]
          query_string = env["QUERY_STRING"].to_s
          url = "#{scheme}://#{host}#{path}"
          url = "#{url}?#{query_string}" unless query_string.empty?
          url
        end

        ##
        # Configures the root span for this request. This may be called
        # before the request is actually handled because it doesn't depend
        # on the result.
        #
        # @private
        # @param [Google::Cloud::Trace::TraceSpan] span The root span to
        #     configure.
        # @param [Hash] env Rack environment hash
        #
        def configure_span span, env
          span.name = get_path env
          set_basic_labels span.labels, env
          set_extended_labels span.labels,
                              span.trace.trace_context.capture_stack?
          span
        end

        ##
        # Configures standard labels.
        # @private
        #
        def set_basic_labels labels, env
          set_label labels, Google::Cloud::Trace::LabelKey::AGENT, AGENT_NAME
          set_label labels, Google::Cloud::Trace::LabelKey::HTTP_HOST,
                    get_host(env)
          set_label labels, Google::Cloud::Trace::LabelKey::HTTP_METHOD,
                    env["REQUEST_METHOD"]
          set_label labels,
                    Google::Cloud::Trace::LabelKey::HTTP_CLIENT_PROTOCOL,
                    env["SERVER_PROTOCOL"]
          set_label labels, Google::Cloud::Trace::LabelKey::HTTP_USER_AGENT,
                    env["HTTP_USER_AGENT"]
          set_label labels, Google::Cloud::Trace::LabelKey::HTTP_URL,
                    get_url(env)
          set_label labels, Google::Cloud::Trace::LabelKey::PID,
                    ::Process.pid.to_s
          set_label labels, Google::Cloud::Trace::LabelKey::TID,
                    ::Thread.current.object_id.to_s
        end

        ##
        # Configures stack and gae labels.
        # @private
        #
        def set_extended_labels labels, capture_stack
          if capture_stack
            Google::Cloud::Trace::LabelKey.set_stack_trace labels,
                                                           skip_frames: 3
          end
          if Google::Cloud::Core::Environment.gae?
            set_label labels, Google::Cloud::Trace::LabelKey::GAE_APP_MODULE,
                      Google::Cloud::Core::Environment.gae_module_id
            set_label labels,
                      Google::Cloud::Trace::LabelKey::GAE_APP_MODULE_VERSION,
                      Google::Cloud::Core::Environment.gae_module_version
          end
        end

        ##
        # Sets the given label if the given value is a proper string.
        #
        # @private
        # @param [Hash] labels The labels hash.
        # @param [String] key The key of the label to set.
        # @param [Object] value The value to set.
        #
        def set_label labels, key, value
          labels[key] = value if value.is_a? ::String
        end

        ##
        # Performs post-request tasks, including adding result-dependent
        # labels to the root span, and adding trace context headers to the
        # HTTP response.
        #
        # @private
        # @param [Google::Cloud::Trace::TraceSpan] span The root span to
        #     configure.
        # @param [Array] result The Rack response.
        #
        def configure_result span, result
          if result.is_a?(::Array) && result.size == 3
            span.labels[Google::Cloud::Trace::LabelKey::HTTP_STATUS_CODE] =
                result[0].to_s
            result[1]["X-Cloud-Trace-Context"] =
                span.trace.trace_context.to_string
          end
          result
        end
      end
    end
  end
end