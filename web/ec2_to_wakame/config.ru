# -*- coding: utf-8 -*-

$LOAD_PATH.unshift "#{File.dirname(__FILE__)}/../../lib/"

require 'ec2_to_wakame'

run Adapters::EC2ToWakame.new
