# -*- coding: utf-8 -*-

require 'sinatra/base'
require 'net/http'
require 'json'
require 'yaml'
require 'dcmgr'

module Adapters
  class EC2ToWakame < Sinatra::Base

    disable :sessions
    disable :show_exceptions
    
    before do
      @config = YAML.load_file(File.expand_path('../../config/ec2_to_wakame.yml', __FILE__))
    end
    
    get '/' do
      ''
    end
    
    #EC2 Parameters
    # ImageId
    # MinCount
    # MaxCount
    # KeyName
    # SecurityGroup []
    # UserData
    # InstanceType
    # Placement.GroupName
    post '/RunInstances' do
      w_params = {}
      w_params[:image_id]      = params[:ImageId]
      w_params[:instance_spec_id] = params[:InstanceType]
      w_params[:nf_group]      = params[:SecurityGroup]
      w_params[:user_data]     = params[:UserData]
      
      w_params[:host_pool_id]  = @config["host_node_id"]
      w_params[:network_id]    = @config["network_pool_id"]
      
      w_api = URI.parse("http://#{@config["web_api_location"]}:#{@config["web_api_port"]}/api/instances")
      
      req = Net::HTTP::Post.new(w_api.path)
      req.add_field("X_VDC_ACCOUNT_UUID", params[:AWSAccessKeyId])
      
      req.body = ""
      req.form_data = w_params

      res = Net::HTTP.new(w_api.host, w_api.port).start do |http|
        http.request(req)
      end
      
      run_instances_response(JSON.parse(res.body)["id"])
    end
    
    private
    def run_instances_response(instance_ids)
      insts = instance_ids.map { |instance_id| Models::Instance[instance_id] }.compact

      ERB.new(<<__END, nil, '-').result(binding)
<RunInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2011-07-15/"> 
  <requestId></requestId> 
  <reservationId></reservationId> 
  <ownerId><%= insts.first.account.canonical_uuid %></ownerId>
  <groupSet>
<%- insts.first.netfilter_groups.each { |group| -%>
    <item>
      <groupId><%=group.canonical_uuid%></groupId>
      <groupName><%=group.name%></groupName>
    </item>
<%- } -%>
  </groupSet>
  <instancesSet>
<%- insts.each { |inst| -%>
    <item>
      <instanceId><%=inst.canonical_uuid%></instanceId>
      <imageId><%=inst.image.canonical_uuid%></imageId>
      <instanceState>
        <code></code>
        <name><%=inst.state%></name>
      </instanceState>
      <privateDnsName>#Coming Soon!#</privateDnsName>
      <dnsName>#Coming Soon!#</dnsName>
      <keyName><%=inst.ssh_key_pair.canonical_uuid unless inst.ssh_key_pair.nil? %></keyName>
      <amiLaunchIndex></amiLaunchIndex>
      <instanceType><%=inst.spec.canonical_uuid%></instanceType>
      <launchTime><%=inst.created_at.utc.xmlschema%></launchTime>
      <placement>
        <availabilityZone></availabilityZone>
      </placement>
      <monitoring>
        <enabled></enabled>
      </monitoring>
      <sourceDestCheck></sourceDestCheck>
      <groupSet>
<%- inst.netfilter_groups.each { |group| -%>
         <item>
            <groupId><%=group.canonical_uuid%></groupId>
            <groupName><%=group.name%></groupName>
         </item>
<%- } -%>
      </groupSet>
      <virtualizationType></virtualizationType>
      <clientToken/>
      <tagSet/>
      <hypervisor>isnt.hypervisor</hypervisor>
    </item>
<%- } -%>
  </instancesSet>
</RunInstancesResponse>
__END
    end
  end
end
