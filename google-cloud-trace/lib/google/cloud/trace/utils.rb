# Copyright 2014 Google Inc. All rights reserved.
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


module Google
  module Cloud
    module Trace
      ##
      # Utils provides some internal utility methods for Trace.
      #
      # @private
      #
      module Utils
        ##
        # Convert a Ruby Time object to a timestamp proto.
        #
        # @private
        #
        def self.time_to_proto time
          Google::Protobuf::Timestamp.new seconds: time.to_i,
                                          nanos: time.nsec
        end

        ##
        # Convert a Timestamp proto to a Ruby Time object.
        #
        # @private
        #
        def self.proto_to_time proto
          Time.at(proto.seconds, Rational(proto.nanos, 1000))
        end
      end
    end
  end
end
