#
# Author:: Daniel DeLeo (<dan@chef.io>)
# Author:: Prajakta Purohit (prajakta@chef.io>)
# Auther:: Tyler Cloke (<tyler@opscode.com>)
#
# Copyright:: Copyright 2012-2018, Chef Software Inc.
# License:: Apache License, Version 2.0
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
#

require "uri"
require "securerandom"
require "chef/event_dispatch/base"

class Chef
  class ActionCollection < EventDispatch::Base
    include Enumerable

    ActionReport = Struct.new(:new_resource,
                                :current_resource,
                                :action,
                                :exception,
                                :elapsed_time,
                                :nesting_level) do

      def self.new_with_current_state(new_resource, action, current_resource)
        report = new
        report.new_resource = new_resource
        report.action = action
        report.current_resource = current_resource
        report
      end

      def self.new_for_exception(new_resource, action, exception)
        report = new
        report.new_resource = new_resource
        report.action = action
        report.exception = exception
        report
      end

      def finish
        self.elapsed_time = new_resource.elapsed_time
      end

      def success?
        !exception
      end
    end

    attr_reader :updated_resources
    attr_reader :total_res_count
    attr_reader :pending_updates
    attr_reader :pending_update
    attr_reader :status
    attr_reader :exception
    attr_reader :error_descriptions
    attr_reader :run_status

    def initialize(run_context)
      @updated_resources  = []
      @total_res_count    = 0
      @status             = "success"
      @error_descriptions = {}
      @expanded_run_list  = {}
      @pending_updates    = []

      run_context.action_collection = self
    end

    def each(&block)
      updated_resources.each(&block)
    end

    # mildly janky:  this is a factory method to create a dup of the action_collection
    # filtered by the nesting level -- used to get an action_collection of only the
    # top level resources.  bypasses issues like Enumerable not having a #size method and
    # Enumerator not have a #last method.  keeps the filtering logic in this class, but
    # allows callers to get at the real actual updated_resources array.  thanks, ruby.
    #
    def filtered_collection(max_nesting: 0)
      collection = dup
      collection.updated_resources.select! { |i| i.nesting_level <= max_nesting }
      collection
    end

    def run_started(run_status)
      @run_status = run_status
    end

    def resource_current_state_loaded(new_resource, action, current_resource)
      pending_updates.push(ActionReport.new_with_current_state(new_resource, action, current_resource))
    end

    def resource_up_to_date(new_resource, action)
      pending_updates.pop
      @pending_update = nil
      @total_res_count += 1
    end

    def resource_skipped(resource, action, conditional)
      pending_updates.pop
      @pending_update = nil
      @total_res_count += 1
    end

    def resource_updated(new_resource, action)
      @pending_update = pending_updates.pop
      @total_res_count += 1
    end

    def resource_failed(new_resource, action, exception)
      if !pending_updates.empty? && pending_updates.last.new_resource == new_resource
        # we failed after loading the current_resource
        @pending_update = pending_updates.pop
      else
        # we failed before loading the current_resource
        @pending_update = ActionReport.new_for_exception(new_resource, action, exception)
      end

      description = Formatters::ErrorMapper.resource_failed(new_resource, action, exception)
      @error_descriptions = description.for_json
      @total_res_count += 1
    end

    def resource_completed(new_resource)
      if @pending_update
        @pending_update.finish

        # Verify if the resource has sensitive data
        # and create a new blank resource with only
        # the name so we can report it back without
        # sensitive data
        if @pending_update.new_resource.sensitive
          klass = @pending_update.new_resource.class
          resource_name = @pending_update.new_resource.name
          @pending_update.new_resource = klass.new(resource_name)
        end

        @pending_update.nesting_level = pending_updates.length

        updated_resources << @pending_update
      end
    end

    def run_completed(node)
      @status = "success"
    end

    def run_failed(exception)
      @exception = exception
      @status = "failure"
    end

    def run_list_expanded(run_list_expansion)
      @expanded_run_list = run_list_expansion
    end

    def node_name
      run_status.node.name
    end

    def start_time
      run_status.start_time
    end

    def end_time
      run_status.end_time
    end

    def run_list_expand_failed(node, exception)
      description = Formatters::ErrorMapper.run_list_expand_failed(node, exception)
      @error_descriptions = description.for_json
    end

    def cookbook_resolution_failed(expanded_run_list, exception)
      description = Formatters::ErrorMapper.cookbook_resolution_failed(expanded_run_list, exception)
      @error_descriptions = description.for_json
    end

    def cookbook_sync_failed(cookbooks, exception)
      description = Formatters::ErrorMapper.cookbook_sync_failed(cookbooks, exception)
      @error_descriptions = description.for_json
    end

    private

    def action_tracking_enabled?
      Chef::Config[:enable_reporting] && !Chef::Config[:why_run]
    end
  end
end
