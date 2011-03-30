#! /usr/bin/env lua

--[[
    
    fluksod.lua - Lua part of the Flukso daemon

    Copyright (C) 2011 Bart Van Der Meerssche <bart.vandermeerssche@flukso.net>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

]]--


local dbg        = require 'dbg'
local nixio      = require 'nixio'
nixio.fs         = require 'nixio.fs'
local uci        = require 'luci.model.uci'.cursor()
local httpclient = require 'luci.httpclient'
local data       = require 'flukso.data'

local arg = arg or {} -- needed when this code is not loaded via the interpreter

local DEBUG		= (arg[1] == '-d')

local DAEMON 		= os.getenv('DAEMON') or 'fluksod'
local DAEMON_PATH 	= os.getenv('DAEMON_PATH') or '/var/run/' .. DAEMON

local DELTA_PATH	= '/var/run/spid/delta'
local DELTA_PATH_IN	= DELTA_PATH .. '/in'
local DELTA_PATH_OUT	= DELTA_PATH .. '/out'

local O_RDWR		= nixio.open_flags('rdwr')
local O_RDWR_NONBLOCK   = nixio.open_flags('rdwr', 'nonblock')
local O_RDWR_CREAT	= nixio.open_flags('rdwr', 'creat')

local POLLIN            = nixio.poll_flags('in')

-- parse and load /etc/config/flukso
local FLUKSO		= uci:get_all('flukso')
local WAN_ENABLED	= true
local WAN_INTERVAL	= 300
local LAN_ENABLED	= true
local TIMESTAMP_MIN	= 1234567890

-- set WAN parameters
local WAN_FILTER = { [1] = {}, [2] = {}, [3] = {} }
WAN_FILTER[1].span	= 60
WAN_FILTER[1].offset	= 0
WAN_FILTER[2].span	= 900
WAN_FILTER[2].offset	= 7200
WAN_FILTER[3].span	= 86400
WAN_FILTER[3].offset	= 172800

local WAN_BASE_URL	= 'https://api.flukso.net/sensor/'
local WAN_KEY		= '0123456789abcdef0123456789abcdef'
uci:foreach('system', 'system', function(x) WAN_KEY = x.key end) -- quirky but it works

-- https headers
local FLUKSO_VERSION    = '000'
uci:foreach('system', 'system', function(x) FLUKSO_VERSION = x.version end) -- quirky but it works, again

local USER_AGENT        = 'Fluksometer v' .. FLUKSO_VERSION
local CACERT		= '/etc/ssl/certs/flukso.ca.crt'

-- set LAN parameters
local LAN_POLISH_CUTOFF	= 60
local LAN_PUBLISH_PATH	= DAEMON_PATH .. '/sensor'

function dispatch(wan_child, lan_child)
	return coroutine.create(function()
		local delta = { fdin  = nixio.open(DELTA_PATH_IN, O_RDWR_NONBLOCK),
                                fdout = nixio.open(DELTA_PATH_OUT, O_RDWR) }

		if delta.fdin == nil or delta.fdout == nil then
			-- TODO output to syslog
			print('Error. Unable to open the delta fifos.')
			print('Exiting...')
			os.exit(1)
		end

		-- TODO acquire an exclusive lock on the delta fifos or exit

		local function tolua(num)
			return num + 1
		end

		for line in delta.fdout:linesource() do
			if DEBUG then
				print(line)
			end

			local timestamp, data = line:match('^(%d+)%s+([%d%s]+)$')
			timestamp = tonumber(timestamp)

			for i, counter, extra in data:gmatch('(%d+)%s+(%d+)%s+(%d+)') do
				i = tonumber(i)
				counter = tonumber(counter)
				extra = tonumber(extra)

				-- map index(+1!) to sensor id and sensor type
				local sensor_id = FLUKSO[tostring(tolua(i))]['id']
				local sensor_type = FLUKSO[tostring(tolua(i))]['type']

				-- resume both branches
				if WAN_ENABLED then
					-- TODO send incoming pulses to syslog
					coroutine.resume(wan_child, sensor_id, timestamp, counter)
				end

				if LAN_ENABLED then
					if sensor_type == 'analog' then
						coroutine.resume(lan_child, sensor_id, timestamp, extra)

					elseif sensor_type == 'pulse' then
						coroutine.resume(lan_child, sensor_id, timestamp, false, counter, extra)
					end
				end
				-- check in the e branch whether the counter has increased, if not then discard
				-- chech in both branches whether timestamp has increased
				-- or do we override??
			end 
		end
	end)
end

function wan_buffer(child)
	return coroutine.create(function(sensor_id, timestamp, counter)
		local measurements = data.new()
		local threshold = timestamp + WAN_INTERVAL
		local previous = {}

		while true do
			if not previous[sensor_id] then
				previous[sensor_id] = {}
				-- use the first received counter value as guard
				previous[sensor_id].timestamp = timestamp
				previous[sensor_id].counter = counter
			end

			if timestamp > TIMESTAMP_MIN
				and timestamp > (previous[sensor_id].timestamp or 0)
				and counter ~= (previous[sensor_id].counter or 0) 
				then

				measurements:add(sensor_id, timestamp, counter)
				previous[sensor_id].timestamp = timestamp
				previous[sensor_id].counter = counter
			end

			if timestamp > threshold and next(measurements) then  --checking whether table is not empty
				coroutine.resume(child, measurements)
				threshold = timestamp + WAN_INTERVAL
			end

			sensor_id, timestamp, counter = coroutine.yield()
		end
	end)
end

function filter(child, span, offset)
	return coroutine.create(function(measurements)
		while true do
			measurements:filter(span, offset)
			coroutine.resume(child, measurements)
			measurements = coroutine.yield()
		end
	end)
end


function send(child)
	return coroutine.create(function(measurements)
		local headers = {}
  		headers['Content-Type'] = 'application/json'
		headers['X-Version'] = '1.0'
		headers['User-Agent'] = USER_AGENT

		local options = {}
		options.sndtimeo = 5
		options.rcvtimeo = 5
		options.method  = 'POST'
		options.tls_context_set_verify = 'peer'
		options.cacert = CACERT
		options.headers = headers

		while true do
			local sensors = measurements:get_sensors()
			local measurements_json = measurements:json_encode()
			local http_persist = httpclient.create_persistent()

			for i, sensor_id in ipairs(sensors) do
				if i ~= #sensors then
					options.headers['Connection'] = 'keep-alive'
				else
					options.headers['Connection'] = 'close'
				end

				options.body = '{"measurements":' .. measurements_json[sensor_id] .. '}'
				options.headers["Content-Length"] = tostring(#options.body)
				
				local hash = nixio.crypto.hmac('sha1', WAN_KEY)
				hash:update(options.body)
				options.headers['X-Digest'] = hash:final()

				local response, code, msg = http_persist(WAN_BASE_URL .. sensor_id,  options)

				if response then
					-- TODO send response string to syslog
					measurements:clear(sensor_id)
				end
			end

			coroutine.resume(child, measurements)
			measurements = coroutine.yield()
		end
	end)
end

function gc(child)
	return coroutine.create(function(measurements)
		while true do
			collectgarbage() -- force a complete garbage collection cycle
			coroutine.resume(child, measurements)
			measurements = coroutine.yield()
		end
	end)
end

function lan_buffer(child)
	return coroutine.create(function(sensor_id, timestamp, power, counter, msec)
		local measurements = data.new()
		local previous = {}

		local function diff(x, y)  -- calculates y - x
			if y >= x then
				return y - x
			else -- y wrapped around 32-bit boundary
				return 4294967296 - x + y
			end
		end

		while true do
			if not previous[sensor_id] then
				previous[sensor_id] = {}
			end

			if timestamp > TIMESTAMP_MIN and timestamp > (previous[sensor_id].timestamp or 0) then
				if not power then  -- we're dealing pulse message so first calculate power
					if previous[sensor_id].msec and msec > previous[sensor_id].msec then
						power = math.floor(diff(previous[sensor_id].counter, counter) /
                        	                                   diff(previous[sensor_id].msec, msec) * 3.6 * 10^6 + 0.5)

					end

					-- if msec decreased, just update the value in the table
					-- but don't make any power calculations since the AVR might have gone through a reset
					previous[sensor_id].msec = msec
					previous[sensor_id].counter = counter
				end

				if power then
					measurements:add(sensor_id, timestamp, power)
					previous[sensor_id].timestamp = timestamp
				end
			end

			if next(measurements) then  --checking whether table is not empty
				coroutine.resume(child, measurements)
			end

			sensor_id, timestamp, power, counter, msec = coroutine.yield()
		end
	end)
end

function polish(child, cutoff)
	return coroutine.create(function(measurements)
		while true do
			measurements:fill()
			measurements:truncate(cutoff)
			coroutine.resume(child, measurements)
			measurements = coroutine.yield()
		end
	end)
end

function publish(child, dir)
	return coroutine.create(function(measurements)
		nixio.fs.mkdirr(dir)

		for file in nixio.fs.dir(dir) do
			nixio.fs.unlink(file)
		end

		while true do
			local measurements_json = measurements:json_encode()

			for sensor_id, json in pairs(measurements_json) do
				local file = dir .. '/' .. sensor_id
				
				nixio.fs.unlink(file)
				fd = nixio.open(file, O_RDWR_CREAT)
				fd:write(json)
				fd:close()
			end

			coroutine.resume(child, measurements)
			measurements = coroutine.yield()
		end
	end)
end

function debug(child)
	return coroutine.create(function(measurements)
		while true do
			if DEBUG then
				dbg.vardump(measurements)
			end

			if child then
				coroutine.resume(child, measurements)
			end

			measurements = coroutine.yield()
		end
	end)
end

local wan_chain =
	wan_buffer(
		filter(
			filter(
				filter(
					send(
						gc(
							debug(nil)
						)
					)
				, WAN_FILTER[3].span, WAN_FILTER[3].offset)
			, WAN_FILTER[2].span, WAN_FILTER[2].offset)
		, WAN_FILTER[1].span, WAN_FILTER[1].offset)
	)

local lan_chain =
	lan_buffer(
		polish(
			publish(
				debug(nil)
			, LAN_PUBLISH_PATH)
		, LAN_POLISH_CUTOFF)
	)

local chain = dispatch(wan_chain, lan_chain)

coroutine.resume(chain)
