# frozen_string_literal: true

require_relative "churros_git_bot/version"
require "set"
require "gitlab"
require "httparty"

module ChurrosGitBot
  extend self

  def gitlab
    Gitlab.client(endpoint: "https://git.inpt.fr/api/v4", private_token: ENV["GITLAB_PRIVATE_TOKEN"])
  end

  def graphql(query, variables)
    endpoint = "https://git.inpt.fr/api/graphql"
    response = HTTParty.post(endpoint, body: { query: query, variables: variables }.to_json, headers: { "Content-Type" => "application/json" })
    JSON.parse(response.body)
  end

  OK = '<span title="does not import global $me or zeus" style="color: gray; font-weight: bold;">OK</span>'
  YEP = '<span title="uses Houdini" style="color: green; font-weight: bold;">YEP</span>'
  NOPE = '<span title="imports global $me or zeus" style="color: red; font-weight: bold;">NOPE</span>'

  class Error < StandardError; end

  # Your code goes here...
  

  
  def wait_until_current_build_job_is_done(project_id, merge_request_id)
    is_active = true
    while is_active 
      query = <<~GRAPHQL
        query ($projectPath: ID!, $mrIID: String!) {
          project(fullPath: $projectPath) {
            mergeRequest(iid: $mrIID) {
              pipelines(first: 1) {
                nodes {
                  job(name: "build") {
                    active
                  }
                }
              }
            }
          }
        }
      GRAPHQL

      project_path = gitlab.project(project_id).path_with_namespace
      is_active = graphql(query, { projectPath: project_path, mrIID: merge_request_id }).dig("data", "project", "mergeRequest", "pipelines", "nodes", 0, "job", "active")
      sleep 5 if is_active
    end
  end


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
      note = (gitlab.merge_request_notes project_id, merge_request_id).filter { |note| note.author.username == username && note.body.include?("houdinified") }.first

      if note && note.body.strip != comment_content.strip
        gitlab.delete_merge_request_note project_id, merge_request_id, note.id
        gitlab.create_merge_request_note project_id, merge_request_id, comment_content
      elsif !note
        gitlab.create_merge_request_note project_id, merge_request_id, comment_content
      end
    end
  end

  def build_failed_because_of_volta(project_id, merge_request_id)
    project_path = gitlab.project(project_id).path_with_namespace
    # do a GraphQL request since the ruby gem does not wrap pipelines
    query = <<~GRAPHQL
      query ($projectPath: ID!, $mrIID: String!) {
        project(fullPath: $projectPath) {
          mergeRequest(iid: $mrIID) {
            pipelines(first: 1) {
              nodes {
                iid
                job(name: "build") {
                  status, trace {
                    htmlSummary(lastLines: 20)
                  }, webPath
                }
              }
            }
          }
        }
      }
    GRAPHQL
    project_path = gitlab.project(project_id).path_with_namespace
    pipeline = graphql(query, { projectPath: project_path, mrIID: merge_request_id }).dig("data", "project", "mergeRequest", "pipelines", "nodes", 0)
    job = pipeline["job"]
    unless job["status"] == "FAILED" then return end

    trace = job["trace"]["htmlSummary"]
    if trace.include? "Volta error: Could not unpack"
      gitlab.create_merge_request_note project_id, merge_request_id, "Build failed because Volta is dumb (“Volta error: Could not unpack …”) — [see logs for pipeline ##{pipeline["iid"]}](https://git.inpt.fr/#{job["webPath"]})"
    end
  end
end
