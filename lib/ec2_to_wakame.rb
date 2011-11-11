# -*- coding: utf-8 -*-

require 'sinatra/base'
require 'net/http'
require 'net/https'
require 'json'
require 'yaml'

module Net
  module HTTPHeader
    # Monkey patch to fix arrays in form_data
    def set_form_data(params, sep = '&')
      self.body = params.map {|k,v|
        if v.is_a?(Array)
          v.map { |vv|
            "#{urlencode("#{k.to_s}[]")}=#{urlencode(vv.to_s)}"
          }
        else
          "#{urlencode(k.to_s)}=#{urlencode(v.to_s)}"
        end
      }.flatten.join(sep)
      self.content_type = 'application/x-www-form-urlencoded'
    end
  end
end

module Adapters
  class EC2ToWakame < Sinatra::Base
    Hypervisor = "kvm"

    disable :sessions
    disable :show_exceptions
    
    before do
      @config = YAML.load_file(File.expand_path('../../config/ec2_to_wakame.yml', __FILE__))
      @w_api  = "#{ {true => "https", false => "http"}[@config["use_ssl"]] }://#{@config["web_api_location"]}:#{@config["web_api_port"]}/api"
    end
    
    get '/' do
      p params if @config["verbose_requests"]
    
      begin
        self.send(params["Action"],params)
      rescue NoMethodError => e
        raise unless params["Action"] == e.name.to_s
        "Error: Unsupported Action: #{params["Action"]}\n"
      end
    end
    
    post '/' do
      p params if @config["verbose_requests"]
    
      begin
        self.send(params["Action"],params)
      rescue NoMethodError => e
        raise unless params["Action"] == e.name.to_s
        "Error: Unsupported Action: #{params["Action"]}\n"
      end
    end
    
    #EC2 Parameters
    # ImageId
    # MinCount
    # MaxCount
    # KeyName
    # SecurityGroup.n
    # UserData
    # InstanceType
    # Placement.AvailabilityZone
    def RunInstances(params)
      w_params = {}
      w_params[:image_id]         = params[:ImageId]
      w_params[:instance_spec_id] = params[:InstanceType]
      w_params[:nf_group]         = amazon_list_to_array("SecurityGroup",params)
      w_params[:user_data]        = params[:UserData]
      w_params[:ssh_key]          = params[:KeyName]
      
      w_params[:host_id]  = params["Placement.AvailabilityZone"]
      w_params[:network_id]    = @config["network_pool_id"]
      
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
      
      create_res = []
      (1..instances_to_start).each { |i|
        create_res << make_request("#{@w_api}/instances",Net::HTTP::Post,params[:AWSAccessKeyId],w_params)
      }
      
      inst_maps = create_res.map { |res| JSON.parse(res.body) }.flatten

      run_instances_response(params[:AWSAccessKeyId],inst_maps)
    end
    
    #EC2 Parameters
    # InstanceId.n
    def TerminateInstances(params)
      insts = amazon_list_to_array("InstanceId",params)
      
      insts.each { |inst|
        delete_res = make_request("#{@w_api}/instances/#{inst}",Net::HTTP::Delete,params[:AWSAccessKeyId])
      }
      
      #TODO: Check response for errors
      
      terminate_instances_response(insts)
    end
    
    #Params
    # InstanceId.n
    def DescribeInstances(params)
      insts = amazon_list_to_array("InstanceId",params)

      show_res = make_request("#{@w_api}/instances",Net::HTTP::Get,params[:AWSAccessKeyId])
      
      res = JSON.parse(show_res.body).first["results"]
      descs = []
      if insts.empty?
        descs = res
      else
        res.each { |r|
          descs << r if insts.member?(r["id"])
        }
      end
      describe_instances_response(params[:AWSAccessKeyId],descs)
    end
    
    #Params
    # InstanceId.n
    def DescribeImages(params)
      res = make_request("#{@w_api}/images",Net::HTTP::Get,params[:AWSAccessKeyId])
      
      imgs = amazon_list_to_array("ImageId",params)
      wakame_imgs = JSON.parse(res.body).first["results"]
      
      wakame_imgs.delete_if { |w_img|
        not imgs.member?(w_img["id"])
      } unless imgs.empty?
      
      describe_images_response(wakame_imgs)
    end
    
    private
    
    def make_request(uri,type,accesskey,form_data = nil)
      api = URI.parse(uri)

      req = type.new(api.path)
      req.add_field("X_VDC_ACCOUNT_UUID", accesskey)
      
      req.body = ""
      req.set_form_data(form_data) unless form_data.nil?

      session = Net::HTTP.new(api.host, api.port)
      session.use_ssl = @config["use_ssl"]

      res = session.start do |http|
        http.request(req)
      end
      
      res
    end
    
    # mask = 'Group'
    # params = {Group.1 = "joske", Group.2 = "jefke", Group.3 = "jantje"}
    #
    # Values in _params_ that don't conform to _mask_ will be ignored
    # 
    # ["joske", "jefke", "jantje"]
    def amazon_list_to_array(mask,params)
      arr = []
      i = 1
      params.each { |key,value|
        if key == "#{mask}.#{i}"
          arr << value
          i += 1
        end
      }
      arr
    end
    
    def trim_uuid(uuid)
      raise ArgumentError, "uuid must be a String" unless uuid.is_a? String
      uuid.split("-").last
    end
    
    def describe_images_response(img_maps)
      ERB.new(<<__END, nil, '-').result(binding)
<DescribeImagesResponse xmlns="http://ec2.amazonaws.com/doc/2011-07-15/">
  <requestId></requestId> 
  <imagesSet>
<%- img_maps.each { |img_map| -%>
    <item>
      <imageId><%=img_map["id"]%></imageId>
      <imageLocation><%=img_map["source"]%></imageLocation>
      <imageState><%=img_map["state"]%></imageState>
      <imageOwnerId><%=img_map["account_id"]%></imageOwnerId>
      <isPublic><%=img_map["is_public"]%></isPublic>
      <architecture><%=img_map["arch"]%></architecture>
      <imageType></imageType>
      <kernelId></kernelId>
      <ramdiskId></ramdiskId>
      <imageOwnerAlias></imageOwnerAlias>
      <name></name>
      <description><%=img_map["description"]%></description>
      <rootDeviceType></rootDeviceType>
      <rootDeviceName></rootDeviceName>
      <blockDeviceMapping>
        <item>
          <deviceName></deviceName>
          <ebs>
            <snapshotId></snapshotId>
            <volumeSize></volumeSize>
            <deleteOnTermination></deleteOnTermination>
          </ebs>
        </item>
      </blockDeviceMapping>
      <virtualizationType></virtualizationType>
      <tagSet/>
      <hypervisor><%=self.class::Hypervisor%></hypervisor>
    </item>
<%- } -%>
  </imagesSet>
</DescribeImagesResponse>
__END
    end
    
    def describe_instances_response(account_id,inst_maps)
      ERB.new(<<__END, nil, '-').result(binding)
<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2011-07-15/">
  <requestId></requestId>
  <reservationSet>
<%- inst_maps.each { |inst_map| -%>
    <item>
      <reservationId></reservationId>
      <ownerId><%=account_id%></ownerId>
      <groupSet/>
      <instancesSet>
        <item>
          <instanceId><%=inst_map["id"]%></instanceId>
          <imageId><%=inst_map["image_id"]%></imageId>
          <instanceState>
            <code></code>
            <name><%=inst_map["status"]%></name>
          </instanceState>
          <privateDnsName><%=inst_map["network"].first["dns_name"] unless inst_map["network"].nil? || inst_map["network"].empty?%></privateDnsName>
          <dnsName><%=inst_map["network"].first["nat_dns_name"] unless inst_map["network"].nil? || inst_map["network"].empty?%></dnsName>
          <reason/>
          <keyName><%=inst_map["ssh_key_pair"]%></keyName>
          <amiLaunchIndex></amiLaunchIndex>
          <productCodes/>
          <instanceType><%=inst_map["instance_spec_id"]%></instanceType>
          <launchTime><%=inst_map["created_at"]%></launchTime>
          <placement>
            <availabilityZone><%=inst_map["host_node"]%></availabilityZone>
            <groupName><%=inst_map["host_node"]%></groupName>
          </placement>
          <kernelId></kernelId>
          <ramdiskId></ramdiskId>
          <monitoring>
            <state></state>
          </monitoring>
          <privateIpAddress><%=inst_map["vif"].first["ipv4"]["address"] unless inst_map["vif"].nil? || inst_map["vif"].empty? || inst_map["vif"].first["ipv4"].nil? %></privateIpAddress>
          <ipAddress><%=inst_map["vif"].first["ipv4"]["nat_address"] unless inst_map["vif"].nil? || inst_map["vif"].empty? || inst_map["vif"].first["ipv4"].nil? %></ipAddress>
          <sourceDestCheck></sourceDestCheck>
          <groupSet>
<%- inst_map["netfilter_groups"].each { |group| -%>
            <item>
              <groupId><%=group%></groupId>
              <groupName></groupName>
            </item>
<%- } -%>
          </groupSet>
          <architecture><%=inst_map["arch"]%></architecture>
          <rootDeviceType></rootDeviceType>
          <rootDeviceName></rootDeviceName>
          <blockDeviceMapping>
            <item>
              <deviceName></deviceName>
              <ebs>
                <volumeId></volumeId>
                <status></status>
                <attachTime></attachTime>
                <deleteOnTermination></deleteOnTermination>
              </ebs>
            </item>
          </blockDeviceMapping>
          <instanceLifecycle></instanceLifecycle>
          <spotInstanceRequestId></spotInstanceRequestId>
          <virtualizationType></virtualizationType>
          <clientToken/>
          <tagSet/>
          <hypervisor><%=self.class::Hypervisor%></hypervisor>
       </item>
      </instancesSet>
      <requesterId></requesterId>
    </item>
<%- } -%>
  </reservationSet>
</DescribeInstancesResponse>
__END
    end
    
    def terminate_instances_response(inst_maps)
      ERB.new(<<__END, nil, '-').result(binding)
<TerminateInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2011-07-15/">
  <requestId></requestId> 
  <instancesSet>
<%- inst_maps.each { |inst_map| -%>
    <item>
      <instanceId><%=inst_map%></instanceId>
      <currentState>
        <code></code>
        <name></name>
      </currentState>
      <previousState>
        <code></code>
        <name></name>
      </previousState>
    </item>
<%- } -%>
  </instancesSet>
</TerminateInstancesResponse>
__END
    end
    
    def run_instances_response(account_id,inst_maps)
      p inst_maps
      ERB.new(<<__END, nil, '-').result(binding)
<RunInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2011-07-15/">
  <requestId></requestId>
  <reservationId></reservationId>
  <ownerId><%= account_id %></ownerId>
  <groupSet>
<%- inst_maps.first["netfilter_groups"].each { |group| -%>
      <item>
        <groupId><%=group%></groupId>
      </item>
<%- } -%>
  </groupSet>
  <instancesSet>
<%- inst_maps.each { |inst_map| -%>
    <item>
      <instanceId><%=inst_map["id"]%></instanceId>
      <imageId><%=inst_map["image_id"]%></imageId>
      <instanceState>
        <code></code>
        <name><%=inst_map["status"]%></name>
      </instanceState>
      <privateDnsName><%=inst_map["network"].first["dns_name"] unless inst_map["network"].nil? || inst_map["network"].empty?%></privateDnsName>
      <dnsName><%=inst_map["network"].first["nat_dns_name"] unless inst_map["network"].nil? || inst_map["network"].empty?%></dnsName>
      <keyName><%=inst_map["ssh_key_pair"]%></keyName>
      <amiLaunchIndex></amiLaunchIndex>
      <instanceType><%=inst_map["instance_spec_id"]%></instanceType>
      <launchTime><%=inst_map["created_at"]%></launchTime>
      <placement>
        <availabilityZone><%=inst_map["host_node"]%></availabilityZone>
      </placement>
      <monitoring>
        <enabled></enabled>
      </monitoring>
      <sourceDestCheck></sourceDestCheck>
      <groupSet/>
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
