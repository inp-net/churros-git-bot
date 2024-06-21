# frozen_string_literal: true

require_relative "churros_git_bot/version"
require "set"
require "gitlab"

module ChurrosGitBot
  extend self

  def gitlab
    Gitlab.client(endpoint: "https://git.inpt.fr/api/v4", private_token: ENV["GITLAB_PRIVATE_TOKEN"])
  end

  OK = '<span title="does not import global $me or zeus" style="color: gray; font-weight: bold;">OK</span>'
  YEP = '<span title="uses Houdini" style="color: green; font-weight: bold;">YEP</span>'
  NOPE = '<span title="imports global $me or zeus" style="color: red; font-weight: bold;">NOPE</span>'

  class Error < StandardError; end

  # Your code goes here...

  def imports_global_me_store(source)
    symbols_from_lib_session = Set.new

    source.each_line do |line|
      match = line.match(/^\s*import\s+{\s*(\S+)\s*}\s+from\s+(["'])\$lib\/session(?:\.js)?\2/)
      next unless match

      match[1].split(",").map(&:strip).each do |element|
        symbols_from_lib_session.add(element)
      end
    end

    symbols_from_lib_session.include?("me")
  end

  def imports_zeus(source)
    source.match(/^\s*import.+from\s+(["'])\$lib\/zeus(?:\.js)?\1/m)
  end

  def imports_from_houdini(source)
    source.match(/^\s*import.+from\s+(["'])(?:\.\/)?\$houdini\1/m)
  end

  def is_ok(source)
    !imports_global_me_store(source) && !imports_zeus(source)
  end

  def is_houdinified(source)
    is_ok(source) && imports_from_houdini(source)
  end

  def build_comment_parts(filenames)
    results = filenames.map do |filename|
      contents = File.read(filename)
      houdinified = is_houdinified(contents)
      ok = is_ok(contents)
      { houdinified: houdinified, ok: ok, filename: filename }
    end

    def count_if(arr, &predicate)
      arr.count(&predicate)
    end

    ok_count = count_if(results) { |result| result[:ok] }
    houdinified_count = count_if(results) { |result| result[:houdinified] }
    nope_count = count_if(results) { |result| !result[:ok] && !result[:houdinified] }

    stats = "<table>
<tr><th>Status</th><th>Count</th><th>Percentage</th></tr>
<tr><td>#{OK}</td><td>#{ok_count}</td><td>#{(ok_count / results.size.to_f) * 100}%</td></tr>
<tr><td>#{YEP}</td><td>#{houdinified_count}</td><td>#{(houdinified_count / results.size.to_f) * 100}%</td></tr>
<tr><td>#{NOPE}</td><td>#{nope_count}</td><td>#{(nope_count / results.size.to_f) * 100}%</td></tr>
</table>"

    houdinifiable_count = count_if(results) { |result| result[:houdinified] || (!result[:ok] && !result[:houdinified]) }
    houdinified_percentage = (houdinified_count / houdinifiable_count.to_f) * 100

    summary = "

- **#{houdinified_percentage}%** houdinified / houdinifiable files
- **#{count_if(results) { |result| !result[:ok] }}** files to go"

    {
      stats: stats,
      summary: summary,
    }
  end

  def build_comment(parts)
    <<~COMMENT
      #{parts[:stats]}
      #{parts[:summary]}
    COMMENT
  end

  def clone_repo(project_id, clone_url, merge_request_id)
    branch = gitlab.merge_request(project_id, merge_request_id).source_branch
    unless Dir.exist? "churros"
      `git clone #{clone_url} churros`
    end
    Dir.chdir "churros" do
      `git checkout #{branch}`
      `git pull --rebase`
    end
  end

  def update_note(project_id, clone_url, merge_request_id)
    clone_repo project_id, clone_url, merge_request_id
    Dir.chdir "churros/packages/app" do
      pages_paths = Dir.glob("src/routes/**/*.{svelte,ts}")
      components_paths = Dir.glob("src/lib/components/**/*.{svelte,ts}")

      comment_content = build_comment(build_comment_parts(pages_paths + components_paths))
      username = gitlab.user.username
      note = (gitlab.merge_request_notes project_id, merge_request_id).filter { |note| note.author.username == username }.first

      File.write("comment.html", comment_content.strip)
      File.write("old_comment.html", note.body.strip) if note

      if note && note.body.strip != comment_content.strip
        gitlab.delete_merge_request_note project_id, merge_request_id, note.id 
        gitlab.create_merge_request_note project_id, merge_request_id, comment_content
      end
    end
  end
end
