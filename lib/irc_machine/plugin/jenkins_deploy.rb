require 'net/http'
class MutexApp
  attr_reader :name, :last_user
  attr_accessor :deploy_url, :hooks

  def initialize(name)
    @name = name
    @cache = { channel: "" }
    @deploying = false
    @last_user = "agent99"
    @last_state = :initial
    @deploy_lock = Mutex.new

    if block_given?
      yield self
    end
  end

  def deploy!(user, channel)
    # Reactor model, this is safe
    return "Deploy for #{name} in progress by #{last_user}" if @deploying

    @deploying = true
    @last_state = :deploying
    @last_user = user
    @cache[:channel] = channel

    run_hook(:pre_deploy)

    uri = URI(deploy_url)
    Net::HTTP.get(uri)

    return "Deploy started for #{name}"
  end

  def succeed
    last_deploying = @deploying
    @last_state = :successful
    @deploying = false
    run_hook(:success)
    return last_deploying
  end

  def fail
    last_deploying = @deploying
    @last_state = :failure
    @deploying = false
    run_hook(:failure)
    return last_deploying
  end

  def last_state
    @last_state.to_s
  end

  def last_channel
    @cache[:channel]
  end

  def deploying?
    @deploying
  end

  def gsub_run(cmd)
    # FIXME - generic solution
    c = cmd.dup
    cmd.gsub!(/:name/, name)
    `#{c}`
  end

  def run_hook(hook_name)
    if hooks && hook = hooks[hook_name]
      case hook
      when String
        gsub_run(hook)
      when Array
        hook.each { |c| gsub_run(c) }
      end
    end
  end

end

class SymbolicHash < Hash
  def [](k)
    super k.to_sym
  end
end

class IrcMachine::Plugin::JenkinsNotify < IrcMachine::Plugin::Base

  CONFIG_FILE = "jenkins_notify.json"
  SQUIRRELS = %w[
    http://99designs-shipit-squirrels.s3-website-us-east-1.amazonaws.com/ship%20it%20squirrel.png
    http://99designs-shipit-squirrels.s3-website-us-east-1.amazonaws.com/squirrel.png
    http://99designs-shipit-squirrels.s3-website-us-east-1.amazonaws.com/Ship%20it1.jpg
    http://99designs-shipit-squirrels.s3-website-us-east-1.amazonaws.com/Ship%20it2.jpg
  ]


  def initialize(*args)
    @apps = SymbolicHash.new
    load_config.each do |k, v|
      @apps[k] = MutexApp.new(k) do |app|
        app.deploy_url = v[:deploy_url]
        app.hooks = v[:hooks]
      end

      route(:get, %r{/deploy/(#{k})/success}, :rest_success)
      route(:get, %r{/deploy/(#{k})/fail}, :rest_fail)

    end

    super(*args)
  end
  attr_reader :apps

  def receive_line(line)
    # TODO Regex
    if line =~ /^:(\S+)!\S+ PRIVMSG (#+\S+) :#{session.state.nick}:? deploy (\S+)$/
      user = $1.chomp
      channel = $2.chomp
      repo = $3.chomp

      app = apps[repo.to_sym]
      if app.nil?
        session.msg channel, "Unknown repo: #{repo}"
      else
        deploy(app, user, channel)
      end

    elsif line =~ /^:(\S+)!\S+ PRIVMSG (#+\S+) :#{session.state.nick}:? status (\S+)$/
      user = $1.chomp
      channel = $2.chomp
      repo = $3.chomp

      app = apps[repo.to_sym]
      if app.nil?
        session.msg channel, "Unknown repo: #{repo}"
      else
        if app.deploying?
          session.msg channel, "#{user}: #{repo} is currently being deployed by #{app.last_user}"
        else
          session.msg channel, "#{user}: #{repo} is not currently being deployed"
        end
      end
    end
  end

  def rest_success(request, match)
    if app = apps[match[1]]
      if app.succeed
        session.msg app.last_channel, "Deploy of #{app.name} succeeded \\o/ | PING #{app.last_user}"
      end
    else
      not_found
    end
  end

  def rest_fail(request, match)
    if app = apps[match[1]]
      if app.fail
        session.msg app.last_channel, "Deploy of #{app.name} FAILED | PING #{app.last_user}"
      end
    else
      not_found
    end
  end

  private

  def deploy(app, user, channel)
    status = app.deploy!(user, channel)
    if status =~ /Deploy started/
      session.msg channel, SQUIRRELS.sample
    end
    session.msg channel, status
  end

  def load_config
    JSON.load(open(File.expand_path(CONFIG_FILE))).symbolize_keys
  end

end
