# encoding: utf-8
# `compliance_report` custom resource to run Chef Compliance profiles and
# send reports to Chef Compliance
class ComplianceReport < Chef::Resource
  include ComplianceHelpers
  use_automatic_resource_name

  property :name, String, name_property: true

  # to use a chef-compliance server that is _not_ "colocated" with chef-server
  property :server, URI
  property :port, Integer
  property :username, String
  property :password, String
  property :token, String

  # to override the node this report is reported for
  property :node, String # default: node.name
  property :environment, String # default: node.environment

  default_action :execute

  action :execute do
    converge_by "report compliance profiles' results" do
      reports, ownermap = compound_report(profiles)

      blob = node_info
      blob[:reports] = reports
      total_failed = 0
      blob[:reports].each { |k, _| total_failed += blob[:reports][k]['summary']['failure_count'].to_i }
      blob[:profiles] = ownermap

      Chef::Config[:verify_api_cert] = false
      Chef::Config[:ssl_verify_mode] = :verify_none

      url = construct_url(::File.join('/organizations', org, 'inspec'))
      # Chef::Log.debug "url: #{url}"
      rest = Chef::ServerAPI.new(url, Chef::Config)
      begin
        rest.post(url, blob)
      rescue Net::HTTPServerException => e
        case e.message
        when /401/
          Chef::Log.error "#{e} Possible time/date issue on the client."
        when /403/
          Chef::Log.error "#{e} Possible offline Compliance Server or chef_gate auth issue."
        end
        Chef::Log.error 'Report NOT saved to server.'
        raise e if run_context.node.audit.raise_if_unreachable
      end
      fail "#{total_failed} audits have failed.  Aborting chef-client run." if total_failed > 0 && run_context.node.audit.fail_if_any_audits_failed
    end
  end

  # filters resource collection
  def profiles
    run_context.resource_collection.select do |r|
      r.is_a?(ComplianceProfile)
    end.flatten
  end

  def compound_report(*profiles)
    report = {}
    ownermap = {}

    profiles.flatten.each do |prof|
      next unless ::File.exist?(prof.report_path)
      o, p = prof.normalize_owner_profile
      report[p] = ::JSON.parse(::File.read(prof.report_path))
      ownermap[p] = o
    end

    [report, ownermap]
  end

  def node_info
    n = run_context.node
    {
      node: n.name,
      os: {
        # arch: os[:arch],
        release: n['platform_version'],
        family: n['platform'],
      },
      environment: environment || n.environment,
    }
  end

  def org
    Chef::Config[:chef_server_url].split('/').last
  end
end
