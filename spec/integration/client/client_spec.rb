require "support/shared/integration/integration_helper"
require "chef/mixin/shell_out"
require "tiny_server"
require "tmpdir"

describe "chef-client" do

  def recipes_filename
    File.join(CHEF_SPEC_DATA, "recipes.tgz")
  end

  def start_tiny_server(server_opts = {})
    @server = TinyServer::Manager.new(server_opts)
    @server.start
    @api = TinyServer::API.instance
    @api.clear
    #
    # trivial endpoints
    #
    # just a normal file
    # (expected_content should be uncompressed)
    @api.get("/recipes.tgz", 200) do
      File.open(recipes_filename, "rb") do |f|
        f.read
      end
    end
  end

  def stop_tiny_server
    @server.stop
    @server = @api = nil
  end

  include IntegrationSupport
  include Chef::Mixin::ShellOut

  let(:chef_dir) { File.join(File.dirname(__FILE__), "..", "..", "..", "bin") }

  # Invoke `chef-client` as `ruby PATH/TO/chef-client`. This ensures the
  # following constraints are satisfied:
  # * Windows: windows can only run batch scripts as bare executables. Rubygems
  # creates batch wrappers for installed gems, but we don't have batch wrappers
  # in the source tree.
  # * Other `chef-client` in PATH: A common case is running the tests on a
  # machine that has omnibus chef installed. In that case we need to ensure
  # we're running `chef-client` from the source tree and not the external one.
  # cf. CHEF-4914
  let(:chef_client) { "ruby '#{chef_dir}/chef-client' --minimal-ohai" }
  let(:chef_solo) { "ruby '#{chef_dir}/chef-solo' --legacy-mode --minimal-ohai" }

  let(:critical_env_vars) { %w{_ORIGINAL_GEM_PATH GEM_PATH GEM_HOME GEM_ROOT BUNDLE_BIN_PATH BUNDLE_GEMFILE RUBYLIB RUBYOPT RUBY_ENGINE RUBY_ROOT RUBY_VERSION PATH}.map { |o| "#{o}=#{ENV[o]}" } .join(" ") }

  when_the_repository "has a cookbook that uses cheffish resources" do
    before do
      file "cookbooks/x/recipes/default.rb", <<-EOM
        raise "Cheffish was loaded before we used any cheffish things!" if defined?(Cheffish::VERSION)
        ran_block = false
        got_server = with_chef_server 'https://blah.com' do
          ran_block = true
          run_context.cheffish.current_chef_server
        end
        raise "with_chef_server block was not run!" if !ran_block
        raise "Cheffish was not loaded when we did cheffish things!" if !defined?(Cheffish::VERSION)
        raise "current_chef_server did not return its value!" if got_server[:chef_server_url] != 'https://blah.com'
      EOM
      file "config/client.rb", <<-EOM
        local_mode true
        cookbook_path "#{path_to('cookbooks')}"
      EOM
    end

    it "the cheffish DSL is loaded lazily" do
      command = shell_out("#{chef_client} -c \"#{path_to('config/client.rb')}\" -o 'x::default' --no-fork", cwd: chef_dir)
      expect(command.exitstatus).to eql(0)
    end
  end
end
