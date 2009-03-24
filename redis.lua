module('Redis', package.seeall)

require('socket')

-- ########################################################################### --

local protocol = {
    newline  = '\r\n', 
    ok       = 'OK', 
    err      = 'ERR', 
    null     = 'nil', 

    commands = {
        ping    = 'PING', 
        echo    = 'ECHO', 
        set     = 'SET', 
        setnx   = 'SETNX', 
    }, 
}

-- ########################################################################### --

local function _write(client, buffer)
    local bufferType = type(buffer)

    if bufferType == 'string' then
        client.socket:send(buffer)
    elseif bufferType == 'table' then
        for _, chunk in pairs(buffer) do
            client.socket:send(chunk)
        end
    else
        error('Argument error for buffer: ' .. bufferType)
    end
end

local function _receive(client)
    local line, err = client.socket:receive('*l')
    if not err then return line end
end

local function _receive_len(client, len)
    local buffer, err = client.socket:receive(len)
    if not err then return buffer end
end

-- ########################################################################### --

local function _read_response(client, options)
    local res = _receive(client)
    local prefix = res:sub(1, -#res)

    local response_handler = protocol.prefixes[prefix]

    if not response_handler then 
        error("Unknown response prefix: " .. prefix)
    else
        return response_handler(client, res, options)
    end
end

local function _send(client, buffer, options)
    _write(client, buffer)
    return _read_response(client, options)
end

local function _read_line(client, response, options)
    return response:sub(2)
end

local function _read_error(client, response, options)
    -- TODO: we should parse the reply to extract the error message
    return response:sub(2)
end

local function _read_bulk(client, response, options) 
    local str = response:sub(2)
    local len = tonumber(str)

    -- TODO: when len == -1 then the function should return nil

    if not len then 
        error('Cannot parse ' .. str .. ' as data length.')
    else
        local data, err = client.socket:receive(len + 2)
        if not err then return data:sub(1, -3) end
    end
end

local function _read_multibulk(client, response, options)
    local str = response:sub(2)
    -- TODO: add a check if the returned value is indeed a number
    local list_count = tonumber(str)

    if list_count == -1 then 
        return nil
    else
        list = {}

        if list_count > 0 then 
            for i = list_count, 1, -1 do
                table.concat(list, _read_bulk(client, _receive(client), options))
            end
        end

        return list
    end
end

local function _read_number(client, response, options)
    local res = response:sub(2)
    local number = tonumber(res)

    if not number then
        if res == protocol.null then
            return nil
        else
            error('Cannot parse ' .. res .. ' as numeric response.')
        end
    end

    return number
end


-- ########################################################################### --

protocol.prefixes = {
    ['+'] = _read_line, 
    ['-'] = _read_error, 
    ['$'] = _read_bulk, 
    ['*'] = _read_multibulk, 
    [':'] = _read_number, 
}

-- ########################################################################### --

local function raw_cmd(client, buffer)
    return _send(client, buffer .. protocol.newline)
end

local function ping(client)
    return _send(client, protocol.commands.ping .. protocol.newline)
end

local function echo(client, str)
    return _send(client, {
        protocol.commands.echo, ' ', #str, protocol.newline,
        str, protocol.newline
    })
end

local function _set(client, command, key, value)
    return _send(client, {
        command, ' ' , key, ' ', #value, protocol.newline, 
        value, protocol.newline
    })
end

local function set(client, key, value)
    return _set(client, protocol.commands.set, key, value)
end

local function set_preserve(client, key, value)
    return _set(client, protocol.commands.setnx, key, value)
end

-- ########################################################################### --

function connect(host, port)
    local client_socket = socket.connect(host, port)

    if not client_socket then
        error('Could not connect to ' .. host .. ':' .. port)
    end

    return {
        socket       = client_socket, 
        raw_cmd      = raw_cmd, 
        ping         = ping,
        echo         = echo, 
        set          = set, 
        set_preserve = set_preserve, 
    }
end
