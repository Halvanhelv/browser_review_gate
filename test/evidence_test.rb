require "test_helper"

module BrowserReviewGate
  class EvidenceTest < Minitest::Test
    include TestData

    PNG = "\x89PNG\r\n\x1A\n#{"x" * 32}".b
    ZIP = "PK\x03\x04#{"x" * 32}".b

    def setup
      @dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(@dir, "artifacts"))
      File.binwrite(File.join(@dir, "artifacts/home.png"), PNG)
      File.binwrite(File.join(@dir, "artifacts/trace.zip"), ZIP)
    end

    def test_files_become_digests_and_entries_are_scrubbed
      data = prepare("screenshots" => [ "artifacts/home.png" ], "trace" => "artifacts/trace.zip",
        "console_errors" => [ "Failed: Authorization: Bearer abcdefghijklmnop1234" ],
        "network_errors" => [ { "method" => "post", "url" => "https://app.test/api/save?token=secret123#x", "status" => 500 } ])

      evidence = data["cases"].first["evidence"]
      assert_equal %w[screenshot trace], evidence["files"].map { |file| file["kind"] }
      assert_equal Digest::SHA256.hexdigest(PNG), evidence["files"].first["sha256"]
      refute evidence["files"].first.key?("source")
      refute_includes evidence["console_errors"].first, "abcdefghijklmnop1234"
      assert_equal "POST https://app.test/api/save -> 500", evidence["network_errors"].first
      assert Report.new(data.merge("verified_by" => "dev")).valid?
    end

    def test_paths_outside_the_report_directory_are_refused
      outside = File.join(Dir.mktmpdir, "secret.png")
      File.binwrite(outside, PNG)
      File.symlink(outside, File.join(@dir, "artifacts/link.png"))

      [ "../secret.png", "/etc/passwd", "~/x.png", "artifacts/../../secret.png", "artifacts/link.png", "artifacts/missing.png", "" ].each do |path|
        assert_raises(Error, path) { prepare("screenshots" => [ path ]) }
      end
    end

    def test_a_file_must_be_what_its_name_says
      File.binwrite(File.join(@dir, "artifacts/fake.png"), "#!/bin/sh\nrm -rf /\n")
      File.write(File.join(@dir, "artifacts/notes.txt"), "hello")

      assert_raises(Error) { prepare("screenshots" => [ "artifacts/fake.png" ]) }
      assert_raises(Error) { prepare("screenshots" => [ "artifacts/notes.txt" ]) }
      assert_raises(Error) { prepare("trace" => "artifacts/home.png") }
      assert_raises(Error) { prepare("screenshots" => Array.new(11) { "artifacts/home.png" }) }
    end

    def test_links_only_to_listed_https_hosts
      config = Config.new("evidence" => { "link_hosts" => [ "artifacts.example.com" ] })

      assert_equal [ "https://artifacts.example.com/run/1.png" ],
        prepare({ "links" => [ "https://artifacts.example.com/run/1.png" ] }, config: config)["cases"].first["evidence"]["links"]
      [ "http://artifacts.example.com/x", "https://evil.example.com/x", "https://user:pw@artifacts.example.com/x", "javascript:alert(1)" ].each do |link|
        assert_raises(Error, link) { prepare({ "links" => [ link ] }, config: config) }
      end
    end

    def test_unknown_evidence_keys_are_refused
      assert_raises(Error) { prepare("cookies" => [ "session=abc" ]) }
    end

    def test_scrub_masks_common_credentials
      text = "cookie: session_id=abc123; password=hunter2 api_key=XYZ token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlc2ln"

      scrubbed = Evidence.scrub(text)
      %w[abc123 hunter2 XYZ eyJhbGci].each { |secret| refute_includes scrubbed, secret }
    end

    def test_the_publisher_keeps_files_and_refuses_bad_evidence
      shell = FakeShell.new
      report = File.join(@dir, "report.json")
      File.write(report, JSON.generate(report_data("cases" => [ browser_case("BROWSER-1", "Sign in").merge("evidence" => { "screenshots" => [ "artifacts/home.png" ] }) ])))

      Publisher.new(github: FakeGitHub.new, report_path: report, shell: shell).save
      kept = Dir.glob(File.join(File.dirname(shell.saved_path), "evidence", "*.png"))
      assert_equal [ "#{Digest::SHA256.hexdigest(PNG)}.png" ], kept.map { |path| File.basename(path) }

      File.write(report, JSON.generate(report_data("cases" => [ browser_case("BROWSER-1", "Sign in").merge("evidence" => { "screenshots" => [ "../x.png" ] }) ])))
      assert_raises(Error) { Publisher.new(github: FakeGitHub.new, report_path: report, shell: shell).save }
    end

    def test_a_refused_run_keeps_no_files
      shell = FakeShell.new
      report = File.join(@dir, "report.json")
      File.binwrite(File.join(@dir, "artifacts/other.png"), "#{PNG}other".b)
      refused = browser_case("BROWSER-1", "Sign in").merge("url" => nil, "evidence" => { "screenshots" => [ "artifacts/other.png" ] })
      File.write(report, JSON.generate(report_data("cases" => [ refused ])))

      assert_raises(Error) { Publisher.new(github: FakeGitHub.new, report_path: report, shell: shell).save }
      assert_empty Dir.glob(File.join(File.dirname(shell.saved_path), "evidence", "*"))
    end

    private

    def prepare(evidence = nil, config: Config.new, **listed)
      evidence ||= listed
      data = report_data("cases" => [ browser_case("BROWSER-1", "Sign in").merge("evidence" => evidence) ])
      Evidence.new(base_dir: @dir, config: config).process(data)
    end
  end
end
