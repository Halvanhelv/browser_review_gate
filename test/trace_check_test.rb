require "test_helper"
require "zlib"

module BrowserReviewGate
  class TraceCheckTest < Minitest::Test
    include TestData

    STARTED = "2026-11-11T10:00:00Z"
    FINISHED = "2026-11-11T10:04:00Z"

    def setup
      @dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(@dir, "artifacts"))
    end

    def test_a_trace_from_the_tested_commit_on_the_case_page_is_verified
      path = trace(requests: [ request("http://localhost:3000/sign_in", HEAD), request("http://localhost:3000/assets/app.js", nil) ])

      result = check(path)
      assert_equal "verified", result["status"]
      assert_equal HEAD[0, 12], result["revision"]
      assert_equal 2, result["requests"]
    end

    def test_compressed_traces_and_short_revisions_are_read
      path = trace(requests: [ request("http://localhost:3000/sign_in", HEAD[0, 12].upcase) ], deflate: true)

      assert_equal "verified", check(path)["status"]
    end

    def test_a_trace_that_does_not_show_the_run_fails_with_the_reason
      cases = {
        "no response carried" => [ request("http://localhost:3000/sign_in", nil) ],
        "not the tested commit" => [ request("http://localhost:3000/sign_in", OLD) ],
        "was not requested" => [ request("http://localhost:3000/settings", HEAD) ],
        "outside the run" => [ request("http://localhost:3000/sign_in", HEAD, at: "2026-11-10T08:00:00Z") ],
        "no network requests" => []
      }
      cases.each do |finding, requests|
        result = check(trace(requests: requests))
        assert_equal "failed", result["status"], finding
        assert(result["findings"].any? { |text| text.include?(finding) }, "#{finding}: #{result["findings"]}")
      end
    end

    def test_hostile_archives_are_refused_without_exhausting_memory
      bomb = zip("trace.network" => "\0" * (ZipReader::MAX_ENTRY_BYTES + 1), deflate: true)
      assert_raises(Error) { check(bomb) }

      File.binwrite(File.join(@dir, "artifacts/not.zip"), "PK\x03\x04garbage".b)
      assert_raises(Error) { check(File.join(@dir, "artifacts/not.zip")) }

      lying = zip("trace.network" => "x" * 100)
      bytes = File.binread(lying)
      directory = bytes.rindex("PK\x01\x02".b)
      bytes[directory + 24, 4] = [ 10 ].pack("V") # claims 10 bytes uncompressed
      File.binwrite(lying, bytes)
      assert_raises(Error) { check(lying) }
    end

    def test_other_entries_are_never_read
      path = zip("../../etc/passwd" => "root", "resources/x.network" => "{}", "trace.network" => line(request("http://localhost:3000/sign_in", HEAD)))

      assert_equal 1, check(path)["requests"]
    end

    def test_warn_shows_the_result_and_require_makes_it_count
      evidence = { "screenshots" => [], "trace" => "artifacts/trace.zip" }
      trace(requests: [ request("http://localhost:3000/elsewhere", HEAD) ], name: "trace.zip")

      warned = submitted(evidence, Config.new("provenance" => { "trace" => "warn" }))
      assert_equal "failed", warned.cases.first.dig("evidence", "trace_check", "status")
      assert_equal "passed", warned.status_of("BROWSER-1")
      assert_includes warned.markdown, "trace check failed"

      required = submitted(evidence, Config.new("provenance" => { "trace" => "require" }))
      assert_equal "failed", required.status_of("BROWSER-1")
      assert_includes required.submission_errors.join, "trace does not show the run"

      off = submitted(evidence, Config.new)
      assert_nil off.cases.first.dig("evidence", "trace_check")
    end

    def test_require_refuses_a_passing_case_without_a_trace
      config = Config.new("provenance" => { "trace" => "require" })

      assert_includes submitted({ "console_errors" => [] }, config).submission_errors.join, "has no Playwright trace"
      assert_equal "trace", config.policy.dig("agent", "trace") == "always" ? "trace" : nil
    end

    def test_an_agent_cannot_write_its_own_trace_verdict
      data = report_data("cases" => [ browser_case("BROWSER-1", "x").merge("evidence" => { "trace_check" => { "status" => "verified" } }) ])

      assert_raises(Error) { Evidence.new(base_dir: @dir, config: Config.new("provenance" => { "trace" => "require" })).process(data) }
    end

    def test_the_middleware_names_the_commit_and_follows_new_commits
      repo = Dir.mktmpdir
      system("git", "-C", repo, "init", "-q", "-b", "main", exception: true)
      system("git", "-C", repo, "-c", "user.email=a@b.c", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "one", exception: true)
      first = `git -C #{repo} rev-parse HEAD`.strip
      app = RevisionHeader.new(->(_env) { [ 200, {}, [ "ok" ] ] }, root: repo)

      assert_equal first, app.call({})[1]["x-app-revision"]
      sleep 0.01
      system("git", "-C", repo, "-c", "user.email=a@b.c", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "two", exception: true)
      FileUtils.touch(File.join(repo, ".git/refs/heads/main"), mtime: Time.now + 2)
      assert_equal `git -C #{repo} rev-parse HEAD`.strip, app.call({})[1]["x-app-revision"]

      assert_nil RevisionHeader.new(->(_env) { [ 200, {}, [] ] }, root: Dir.mktmpdir).call({})[1]["x-app-revision"]
    end

    private

    def check(path, config: Config.new("provenance" => { "trace" => "require" }))
      TraceCheck.new(config).call(path, tested_sha: HEAD, url: "/sign_in", started_at: STARTED, finished_at: FINISHED)
    end

    def submitted(evidence, config)
      data = report_data("cases" => [ browser_case("BROWSER-1", "Sign in").merge("evidence" => evidence) ],
        "tool" => TOOL.merge("capabilities" => %w[screenshots trace console network]))
      Report.new(Evidence.new(base_dir: @dir, config: config).process(data).merge("verified_by" => "dev"), config: config)
    end

    def request(url, revision, at: "2026-11-11T10:01:00Z")
      headers = revision ? [ { "name" => "X-App-Revision", "value" => revision } ] : []
      { "type" => "resource-snapshot",
        "snapshot" => { "request" => { "method" => "GET", "url" => url }, "response" => { "status" => 200, "headers" => headers }, "startedDateTime" => at } }
    end

    def line(event) = "#{JSON.generate(event)}\n"

    def trace(requests:, deflate: false, name: "trace.zip")
      zip({ "trace.trace" => line({ "type" => "context-options" }), "trace.network" => requests.map { |event| line(event) }.join }, deflate: deflate, name: name)
    end

    # A minimal zip writer, so the tests need no zip library either.
    def zip(entries = nil, deflate: false, name: "trace.zip", **listed)
      entries ||= listed
      local = +"".b
      directory = +"".b
      entries.each do |entry_name, content|
        content = content.b
        data = deflate ? Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS).then { |z| z.deflate(content, Zlib::FINISH).tap { z.close } } : content
        method = deflate ? 8 : 0
        crc = Zlib.crc32(content)
        offset = local.bytesize
        local << [ 0x04034b50, 20, 0, method, 0, 0, crc, data.bytesize, content.bytesize, entry_name.bytesize, 0 ].pack("VvvvvvVVVvv") << entry_name.b << data
        directory << [ 0x02014b50, 20, 20, 0, method, 0, 0, crc, data.bytesize, content.bytesize, entry_name.bytesize, 0, 0, 0, 0, 0, offset ]
          .pack("VvvvvvvVVVvvvvvVV") << entry_name.b
      end
      ending = [ 0x06054b50, 0, 0, entries.size, entries.size, directory.bytesize, local.bytesize, 0 ].pack("VvvvvVVv")
      path = File.join(@dir, "artifacts", name)
      File.binwrite(path, local + directory + ending)
      path
    end
  end
end
