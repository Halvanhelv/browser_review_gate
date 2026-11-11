require "test_helper"

module BrowserReviewGate
  class ConfigTest < Minitest::Test
    def test_defaults_need_no_file
      config = Config.new

      assert_empty config.environments
      assert_nil config.environment
      assert_equal 12, config.scenarios["max_count"]
      assert config.gate["block_on_failure"]
      refute config.gate["require_evidence"]
    end

    def test_environments_are_named_and_one_is_the_default
      config = Config.new("environments" => { "local" => { "url" => "http://localhost:3000", "healthcheck" => "/up" },
                                              "staging" => { "url" => "https://staging.example.com" } },
                          "verification" => { "environment" => "staging" })

      assert_equal "staging", config.environment["name"]
      assert_equal "http://localhost:3000", config.environment("local")["url"]
      assert_raises(Error) { config.environment("production") }
      assert_equal "local", Config.new("environments" => { "local" => { "url" => "http://localhost:3000" } }).environment["name"]
    end

    def test_rejects_what_it_would_otherwise_ignore
      [ { "url" => "http://localhost:3000" },
        { "environments" => { "Local" => { "url" => "http://x" } } },
        { "environments" => { "local" => { "url" => "ftp://x" } } },
        { "environments" => { "local" => { "url" => "http://user:pass@x" } } },
        { "environments" => { "local" => { "healthcheck" => "up" } } },
        { "environments" => { "local" => { "password" => "x" } } },
        { "verification" => { "environment" => "missing" } },
        { "verification" => { "timeout" => 300 } },
        { "verification" => { "fail_on_console_errors" => "yes" } },
        { "evidence" => { "screenshots" => "sometimes" } },
        { "evidence" => { "retention_days" => 0 } },
        { "evidence" => { "link_hosts" => [ "https://bucket.example.com" ] } },
        { "scenarios" => { "max_count" => 31 } },
        { "scenarios" => { "mandatory" => [ { "id" => "has space", "name" => "x" } ] } },
        { "scenarios" => { "mandatory" => [ { "id" => "A", "name" => "x", "run_as" => "root" } ] } },
        { "scenarios" => { "matrix" => { "role" => [] } } },
        { "gate" => { "require_evidence" => 1 } } ].each do |data|
        assert_raises(Error, data.inspect) { Config.new(data) }
      end
    end

    def test_settings_from_0_2_say_where_the_keys_went
      error = assert_raises(Error) { Config.new("url" => "http://localhost:3000", "sign_in" => "seed") }
      assert_includes error.message, "moved under environments.local"
    end

    def test_mandatory_scenarios_follow_paths_and_expand_over_the_matrix
      config = Config.new("scenarios" => {
        "matrix" => { "role" => %w[admin member], "viewport" => %w[desktop mobile] },
        "mandatory" => [ { "id" => "SIGN-IN", "name" => "Sign in", "paths" => [ "app/views/sessions/**" ], "matrix" => true },
                         { "id" => "HOME", "name" => "Open the home page" } ]
      })

      assert_equal [ "HOME" ], config.mandatory_scenarios([ "app/models/user.rb" ]).map { |scenario| scenario["id"] }
      ids = config.mandatory_scenarios([ "app/views/sessions/new.html.erb" ]).map { |scenario| scenario["id"] }
      assert_equal %w[SIGN-IN.admin.desktop SIGN-IN.admin.mobile SIGN-IN.member.desktop SIGN-IN.member.mobile HOME], ids
      assert_includes config.mandatory_scenarios([ "app/views/sessions/new.html.erb" ]).first["name"], "role admin, viewport desktop"
    end

    def test_the_matrix_cannot_grow_without_bound
      matrix = { "a" => %w[a1 a2 a3], "b" => %w[b1 b2 b3], "c" => %w[c1 c2 c3] }
      mandatory = [ { "id" => "X", "name" => "x", "matrix" => true } ]

      error = assert_raises(Error) { Config.new("scenarios" => { "matrix" => matrix, "mandatory" => mandatory }) }
      assert_includes error.message, "27 mandatory cases"
    end

    def test_local_commands_read_the_settings_of_the_default_branch
      shell = Object.new
      def shell.call(*argv) = argv.last.start_with?("origin/HEAD:") ? "environments:\n  local:\n    url: http://localhost:3000\n" : raise(Error, "no")
      config, source = Config.load_trusted(Dir.mktmpdir, shell: shell)

      assert_equal "origin/HEAD", source
      assert_equal "http://localhost:3000", config.environment["url"]

      failing = Object.new
      def failing.call(*) = raise(Error, "no remote")
      assert_equal "working tree", Config.load_trusted(Dir.mktmpdir, shell: failing).last
    end

    def test_the_generated_settings_file_is_valid
      root = Dir.mktmpdir
      Installer.new(root: root, log: StringIO.new, agents: [ "codex" ]).install

      config = Config.load(root)
      assert_equal "local", config.environment["name"]
      assert_equal "on_failure", config.evidence["screenshots"]
    end
  end
end
