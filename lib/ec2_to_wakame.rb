# -*- coding: utf-8 -*-

require 'sinatra/base'
require 'net/http'
require 'json'
require 'yaml'

module Adapters
  class EC2ToWakame < Sinatra::Base
    Hypervisor = "kvm"

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
      #TODO: Check parameters for validity
      w_params = {}
      w_params[:image_id]         = params[:ImageId]
      w_params[:instance_spec_id] = params[:InstanceType]
      w_params[:nf_group]         = params[:SecurityGroup]
      w_params[:user_data]        = params[:UserData]
      
      w_params[:host_pool_id]  = @config["host_node_id"]
      w_params[:network_id]    = @config["network_pool_id"]
      
      w_api = URI.parse("http://#{@config["web_api_location"]}:#{@config["web_api_port"]}/api/instances")
      
      # Start only 1 instance if MinCount and MaxCount aren't set
      params[:MinCount] = 1 if params[:MinCount].nil?
      params[:MaxCount] = params[:MinCount] if params[:MaxCount].nil?
      
      # Determine the amount of instances to start
      if params[:MinCount].to_i > @config["max_instances_to_start"]
        instances_to_start = 0
      else
        instances_to_start = params[:MinCount].to_i
        if params[:MaxCount].to_i > @config["max_instances_to_start"]
          instances_to_start = @config["max_instances_to_start"]
        else
          instances_to_start = params[:MaxCount].to_i
        end
      end
      
      new_instance_ids = []
      (1..instances_to_start).each { |i|
        create_req = Net::HTTP::Post.new(w_api.path)
        create_req.add_field("X_VDC_ACCOUNT_UUID", params[:AWSAccessKeyId])
        
        create_req.body = ""
        create_req.form_data = w_params

        create_res = Net::HTTP.new(w_api.host, w_api.port).start do |http|
          http.request(create_req)
        end
        new_instance_ids << JSON.parse(create_res.body)["id"]
        p "starting instance: #{new_instance_ids[i-1]}"
        sleep 1
      }
      
      #run_instances_response(JSON.parse(res.body)["id"])
      
      # Get all the info we need to construct the EC2 response for started instances
      describe_req = Net::HTTP::Get.new(w_api.path)
      describe_req.add_field("X_VDC_ACCOUNT_UUID", params[:AWSAccessKeyId])
      describe_req.body = ""
      describe_res = Net::HTTP.new(w_api.host, w_api.port).start do |http|
        http.request(describe_req)
      end
      
      inst_maps = JSON.parse(describe_res.body).first["results"]
      inst_maps.delete_if { |inst|
        not new_instance_ids.member?  inst["id"]
      }
      
      run_instances_response(params[:AWSAccessKeyId],inst_maps)
    end
    
    private
    def trim_uuid(uuid)
      raise ArgumentError, "uuid must be a String" unless uuid.is_a? String
      uuid.split("-").last
    end
    
    def run_instances_response(account_id,inst_maps)
      #insts = instance_ids.map { |instance_id| Models::Instance[instance_id] }.compact

      ERB.new(<<__END, nil, '-').result(binding)
<RunInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2011-07-15/">
  <requestId></requestId>
  <reservationId></reservationId>
  <ownerId><%= account_id %></ownerId>
  <groupSet>
<%- inst_maps.first["netfilter_group"].each { |group| -%>
    <item>
      <groupId></groupId>
      <groupName><%=group%></groupName>
    </item>
<%- } -%>
  </groupSet>
  <instancesSet>
<%- inst_maps.each { |inst| -%>
    <item>
      <instanceId><%=inst["id"]%></instanceId>
      <imageId><%=inst["image_id"]%></imageId>
      <instanceState>
        <code></code>
        <name><%=inst["status"]%></name>
      </instanceState>
      <privateDnsName></privateDnsName>
      <dnsName></dnsName>
      <keyName><%=inst["ssh_key_pair"]%></keyName>
      <amiLaunchIndex></amiLaunchIndex>
      <instanceType></instanceType>
      <launchTime><%=inst["created_at"]%></launchTime>
      <placement>
        <availabilityZone></availabilityZone>
      </placement>
      <monitoring>
        <enabled></enabled>
      </monitoring>
      <sourceDestCheck></sourceDestCheck>
      <groupSet>
<%- inst["netfilter_group"].each { |group| -%>
         <item>
            <groupId></groupId>
            <groupName><%=group%></groupName>
         </item>
<%- } -%>
      </groupSet>
      <virtualizationType></virtualizationType>
      <clientToken/>
      <tagSet/>
      <hypervisor><%=self.class::Hypervisor%></hypervisor>
    </item>
<%- } -%>
  </instancesSet>
</RunInstancesResponse>
__END
    end
  end
end
