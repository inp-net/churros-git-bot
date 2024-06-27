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

  def imports_global_me_store(source, filename)
    symbols_from_lib_session = Set.new

    source.each_line do |line|
      match = line.match(/^\s*import\s+{\s*(\S+)\s*}\s+from\s+(["'])\$lib\/session(?:\.js)?\2/)
      next unless match

      match[1].split(",").map(&:strip).each do |element|
        symbols_from_lib_session.add(element)
      end
    end

    result = symbols_from_lib_session.include?("me")
    if result
      puts "Found global $me import in #{filename}"
    end
    result
  end

  def imports_zeus(source, filename)
    if source.match(/^\s*import.+from\s+(["'])\$lib\/zeus(?:\.js)?\1/m)
      puts "Found global zeus import in #{filename}"
      true
    else
      false
    end
  end

  def imports_from_houdini(source, filename)
    if source.match(/^\s*import.+from\s+(["'])(?:\.\/)?\$houdini\1/m)
      puts "Found Houdini import in #{filename}"
      true
    else
      false
    end
  end

  def is_ok(source, filename)
    !imports_global_me_store(source, filename) && !imports_zeus(source, filename)
  end

  def bot_comments_on_mr(project_id, merge_request_id)
    bot_username = gitlab.user.username
    gitlab.merge_request_notes(project_id, merge_request_id).filter { |note| note.author.username == bot_username }
  end

  def add_note_if_changelog_not_modified(project_id, merge_request_id)
    unless modifies_changelog(project_id, merge_request_id)
      unless bot_comments_on_mr(project_id, merge_request_id).any? { |note| note.body.include?("CHANGELOG.md") }
        gitlab.create_merge_request_note project_id, merge_request_id, "Remember to update the CHANGELOG.md if your changes visibly affect end users"
      end
    else
      bot_comments_on_mr(project_id, merge_request_id).filter { |note| note.body.include?("CHANGELOG.md") }.each do |note|
        gitlab.delete_merge_request_note project_id, merge_request_id, note.id
      end
    end
  end

  def new_api_modules_readme_is_filled(project_id, merge_request_id)
    changes = gitlab.merge_request_changes project_id, merge_request_id
    new_files = changes.changes.map { |change| change.new_path }
    Dir.chdir "churros" do
      all_new_filled = !new_files.filter { |new_file| new_file.start_with?("packages/api/src/modules/") and new_file.end_with? "README.md" }.any? do |readme|
        contents = File.open(readme).read
        contents.strip.empty? or contents.include? "TODO: "
      end

      if all_new_filled
        note = bot_comments_on_mr(project_id, merge_request_id).filter { |note| note.body.include?("README.md of new API module") }.first
        if note
          gitlab.delete_merge_request_note project_id, merge_request_id, note.id
        end
      else
        unless bot_comments_on_mr(project_id, merge_request_id).any? { |note| note.body.include?("README.md of new API module") }
          gitlab.create_merge_request_note project_id, merge_request_id, "Remember to fill the README.md of new API module(s)"
        end
      end
      return all_new_filled
    end
  end

  def modifies_changelog(project_id, merge_request_id)
    changes = (gitlab.merge_request_changes project_id, merge_request_id).changes
    changes.map { |change| change.new_path }.include? "CHANGELOG.md"
  end

  def build_comment_parts(filenames)
    results = filenames.map do |filename|
      contents = File.read(filename)
      ok = is_ok(contents, filename)
      houdinified = ok && imports_from_houdini(contents, filename)
      result = { houdinified: houdinified, ok: ok, filename: filename }
      pp result
      result
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

  def update_houdini_progress_note(project_id, clone_url, merge_request_id)
    clone_repo project_id, clone_url, merge_request_id
    Dir.chdir "churros/packages/app" do
      pages_paths = Dir.glob("src/routes/**/*.{svelte,ts}")
      components_paths = Dir.glob("src/lib/components/**/*.{svelte,ts}")

      comment_content = build_comment(build_comment_parts(pages_paths + components_paths))
      username = gitlab.user.username
      note = bot_comments_on_mr(project_id, merge_request_id).filter { |note| note.body.include?("houdinified") }.first

      if note && note.body.strip != comment_content.strip
        gitlab.delete_merge_request_note project_id, merge_request_id, note.id
        gitlab.create_merge_request_note project_id, merge_request_id, comment_content
      elsif !note
        gitlab.create_merge_request_note project_id, merge_request_id, comment_content
      end
    end
  end

  def conflicting_migrations(project_id, merge_request_id)
    Dir.chdir "churros" do
      `git checkout main`
      main = migrations_file_tree_to_hash Dir.children(
        if Dir.exist? "packages/db"
          "packages/db/prisma/migrations/"
        else
          "packages/api/prisma/migrations/"
        end
      )

      `git checkout #{gitlab.merge_request(project_id, merge_request_id).source_branch}`
      branch_migration_folder_path = if Dir.exist? "packages/db"
          "packages/db/prisma/migrations/"
        else
          "packages/api/prisma/migrations/"
        end
      branch = migrations_file_tree_to_hash Dir.children branch_migration_folder_path

      puts "Migrations on main:"
      pp main
      puts "Migrations on branch:"
      pp branch
      

      conflicts = conflicting_prisma_migrations(main, branch)
      existing_note = bot_comments_on_mr(project_id, merge_request_id).filter { |note| note.body.include?("Prisma migrations that conflict with") }.first
      existing_note_ok = bot_comments_on_mr(project_id, merge_request_id).filter { |note| note.body.include?("in order now") }.first
      if conflicts.size > 0
        puts "Detected conflicting migrations: #{conflicts}"
      end

      if conflicts.size > 0 and not existing_note
        puts "Creating note for conflicting migrations"
        project_url = gitlab.project(project_id).web_url
        commit_hash = `git rev-parse HEAD`.strip()
        gitlab.create_merge_request_note(project_id, merge_request_id,
                                         "
## Warning. The merge request contains Prisma migrations that conflict with `main`: 
        
#{conflicts.map do |date, desc|
          "- [`#{to_prisma_migration_dirname date, desc}`](#{project_url}/-/blob/#{commit_hash}/#{branch_migration_folder_path}/#{to_prisma_migration_dirname date, desc})"
        end.join("\n")}

### What???

Merging this branch would leave Prisma with some migrations that were not applied in production. But migrations are supposed to be applied in order, so Prisma would not be able to apply them. 

### What to do?

1. Delete all the mentioned migration folders inside of #{branch_migration_folder_path} in this branch. You don't lose any work that way, because your Prisma schema stores the what you changed. If you edited manually the migrations, be sure to keep a copy of your edits and apply them again
1. Create a new migration Prisma migration
1. That's it :)

        ")
      elsif existing_note and not existing_note_ok and conflicts.size == 0
        gitlab.create_merge_request_note project_id, merge_request_id, "All Prisma migrations are in order now"
      end

      return conflicts.size > 0
    end
  end

  def parse_prisma_migration_dirname(dirname)
    datestring = dirname.split("_").first
    description = (dirname.split("_")[1..-1].join("_").split(".").first || "").gsub("_", " ")
    year, month, day, hour, minute, second = datestring[0..3].to_i, datestring[4..5].to_i, datestring[6..7].to_i, datestring[8..9].to_i, datestring[10..11].to_i, datestring[12..13].to_i
    [Time.new(year, month, day, hour, minute, second), description]
  end

  def to_prisma_migration_dirname(date, description)
    date.strftime("%Y%m%d%H%M%S") + "_" + description.gsub(" ", "_") + ".sql"
  end

  def migrations_file_tree_to_hash(tree)
    (tree.filter { |dirname| dirname != "migration_lock.toml" }.map do |dirname|
      begin
        parse_prisma_migration_dirname dirname
      rescue
        ["", ""]
      end
    end).to_h.filter { |date, description| date != "" }
  end

  def conflicting_prisma_migrations(main, branch)
    branch.filter { |date, description| !main.keys.include? date and date < main.keys.max }
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
    if !pipeline then return end
    job = pipeline["job"]
    if !job then return end
    unless job["status"] == "FAILED" then return end

    trace = job["trace"]["htmlSummary"]
    if trace.include? "Volta error: Could not unpack"
      gitlab.create_merge_request_note project_id, merge_request_id, "Build failed because Volta is dumb (“Volta error: Could not unpack …”) — [see logs for pipeline ##{pipeline["iid"]}](https://git.inpt.fr/#{job["webPath"]})"
    end
  end
end
