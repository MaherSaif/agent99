require 'net/http'
# * Configuration
# Project needs to be configured in jenkins with two parameters:
# - SHA1 : Takes a sha hash to build
# - ID   : Takes unique ID, purely for passing back to work out which build it
#          was that we're looking at
#
# Then configuration in the .json file is
# - {
#     "settings": {
#       "notify": "#builds"
#     },
#     "builds": {
#       "reponame": {
#         "builder_url": "URL GOES HERE",
#         "token"      : "JENKINS_TOKEN",
#       }
#     }
#   }
#

class IrcMachine::Plugin::GithubJenkins < IrcMachine::Plugin::Base

  CONFIG_FILE = "github_jenkins.json"

  USERNAME_MAPPING = {
    "richoH" => "richo"
  }

  attr_reader :settings
  def initialize(*args)
    @id = 0
    @repos = Hash.new
    conf = load_config

    conf["builds"].each do |k, v|
      @repos[k] = OpenStruct.new(v)
      @repos[k].builds = {}
    end

    @settings = OpenStruct.new(conf["settings"])

    route(:post, %r{^/github/jenkins$}, :build_branch)
    route(:post, %r{^/github/jenkins_status$}, :jenkins_status)
    super(*args)
  end

  def build_branch(request, match)
    commit = ::IrcMachine::Models::GithubNotification.new(request.body.read)

    if repo = @repos[commit.repo_name]
      trigger_build(repo, commit)
    else
      not_found
    end
  end

  def jenkins_status(request, match)
    jenkins = ::IrcMachine::Models::JenkinsNotification.new(request.body.read)

    if repo = @repos[jenkins.repo_name]
      commit = repo.builds[jenkins.parameters.id.to_sym]

      commit.author_usernames.each do |author|
        ircnick = USERNAME_MAPPING[author] || author
        session.msg ircnick, "Build status of #{commit.branch} revision #{commit.after} changed to #{jenkins.status}"
      end

    else
      not_found
    end
  end

private

  def trigger_build(repo, commit)
    uri = URI(repo.builder_url)
    id = next_id
    params = defaultParams(repo).merge ({SHA1: commit.after, ID: next_id})

    repo.builds[id.to_sym] = commit

    commit.author_usernames.each do |author|
      ircnick = USERNAME_MAPPING[author] || author
      session.msg ircnick, "Building #{commit.branch} revision #{commit.after}"
    end

    uri.query = URI.encode_www_form(params)
    return Net::HTTP.get(uri).is_a? Net::HTTPSuccess
  end

  def load_config
    JSON.load(open(File.expand_path(CONFIG_FILE)))
  end

  def next_id
    @id += 1
  end

  def defaultParams(repo)
    { token: repo.token }
  end
end
