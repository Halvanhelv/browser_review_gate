module BrowserReviewGate
  # Rack middleware that names the commit the app is serving in a response header, so a Playwright
  # trace shows which code a browser run exercised (`provenance.trace`). Meant for development and
  # test environments only: it reads the checkout's HEAD, and a production app has no business telling
  # visitors its commit.
  #
  #   # config/environments/development.rb
  #   config.middleware.use BrowserReviewGate::RevisionHeader
  #
  # HEAD is read again whenever .git/HEAD or the branch it points to changes, so a new commit shows up
  # without a restart. A worktree with uncommitted changes is still reported as HEAD: publishing a run
  # requires a clean worktree anyway.
  class RevisionHeader
    def initialize(app, header: "X-App-Revision", root: Dir.pwd)
      @app = app
      @header = header.downcase # Rack 3 wants lowercase header names
      @git_dir = git_dir(root)
      @cached = nil
    end

    def call(env)
      status, headers, body = @app.call(env)
      revision = current_revision
      headers[@header] = revision if revision
      [ status, headers, body ]
    end

    private

    def current_revision
      return unless @git_dir

      head_path = File.join(@git_dir, "HEAD")
      head = File.read(head_path).strip
      ref_path = head.start_with?("ref: ") ? File.join(common_dir, head.delete_prefix("ref: ")) : nil
      stamp = [ head, File.mtime(head_path), ref_path && File.exist?(ref_path) ? File.mtime(ref_path) : nil ]
      return @cached.last if @cached&.first == stamp

      @cached = [ stamp, resolve(head, ref_path) ]
      @cached.last
    rescue SystemCallError
      nil
    end

    def resolve(head, ref_path)
      return head[/\A\h{40}\z/] unless ref_path
      return File.read(ref_path).strip[/\A\h{40}\z/] if File.exist?(ref_path)

      # A ref that was packed: look it up in packed-refs.
      packed = File.join(common_dir, "packed-refs")
      ref = head.delete_prefix("ref: ")
      File.exist?(packed) ? File.foreach(packed).find { |line| line.strip.end_with?(" #{ref}") }.to_s[/\A\h{40}/] : nil
    end

    # A worktree's .git is a file pointing at its git directory; branches live in the common one.
    def git_dir(root)
      dot_git = File.join(root, ".git")
      return dot_git if File.directory?(dot_git)
      return unless File.file?(dot_git)

      path = File.read(dot_git)[/\Agitdir: (.+)$/, 1]
      path && File.expand_path(path.strip, root)
    end

    def common_dir
      @common_dir ||= begin
        pointer = File.join(@git_dir, "commondir")
        File.exist?(pointer) ? File.expand_path(File.read(pointer).strip, @git_dir) : @git_dir
      end
    end
  end
end
