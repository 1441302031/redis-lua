module('Redis', package.seeall)

require('socket')

-- ############################################################################

local protocol = {
    newline = '\r\n', ok = 'OK', err = 'ERR', null = 'nil', 
}

-- ############################################################################

local function toboolean(value)
    -- plain and simple
    return value == 1
end

local function _write(self, buffer)
    self.socket:send(buffer)
end

local function _read(self, len)
    if len == nil then len = '*l' end
    local line, err = self.socket:receive(len)
    if not err then return line else error('Connection error: ' .. err) end
end

-- ############################################################################

local function _read_response(self)
    if options and options.close == true then return end

    local res    = _read(self)
    local prefix = res:sub(1, -#res)
    local response_handler = protocol.prefixes[prefix]

    if not response_handler then 
        error("Unknown response prefix: " .. prefix)
    else
        return response_handler(self, res)
    end
end


local function _send_raw(self, buffer)
    -- TODO: optimize
    local bufferType = type(buffer)

    if bufferType == 'string' then
        _write(self, buffer)
    elseif bufferType == 'table' then
        _write(self, table.concat(buffer))
    else
        error('Argument error: ' .. bufferType)
    end

    return _read_response(self)
end

local function _send_inline(self, command, ...)
    if arg.n == 0 then
        _write(self, command .. protocol.newline)
    else
        local arguments = arg
        arguments.n = nil

        if #arguments > 0 then 
            arguments = table.concat(arguments, ' ')
        else 
            arguments = ''
        end

        _write(self, command .. ' ' .. arguments .. protocol.newline)
    end

    return _read_response(self)
end

local function _send_bulk(self, command, ...)
    local arguments = arg
    local data      = tostring(table.remove(arguments))
    arguments.n = nil

    -- TODO: optimize
    if #arguments > 0 then 
        arguments = table.concat(arguments)
    else 
        arguments = ''
    end

    return _send_raw(self, { 
        command, ' ', arguments, ' ', #data, protocol.newline, data, protocol.newline 
    })
end


local function _read_line(self, response)
    return response:sub(2)
end

local function _read_error(self, response)
    local err_line = response:sub(2)

    if err_line:sub(1, 3) == protocol.err then
        error(err_line:sub(5))
    else
        error(err_line)
    end
end

local function _read_bulk(self, response)
    local str = response:sub(2)
    local len = tonumber(str)

    if not len then 
        error('Cannot parse ' .. str .. ' as data length.')
    else
        if len == -1 then return nil end
        local data = _read(self, len + 2)
        return data:sub(1, -3);
    end
end

local function _read_multibulk(self, response)
    local str = response:sub(2)

    -- TODO: add a check if the returned value is indeed a number
    local list_count = tonumber(str)

    if list_count == -1 then 
        return nil
    else
        local list = {}

        if list_count > 0 then 
            for i = 1, list_count do
                table.insert(list, i, _read_bulk(self, _read(self)))
            end
        end

        return list
    end
end

local function _read_integer(self, response)
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

-- ############################################################################

protocol.prefixes = {
    ['+'] = _read_line, 
    ['-'] = _read_error, 
    ['$'] = _read_bulk, 
    ['*'] = _read_multibulk, 
    [':'] = _read_integer, 
}

-- ############################################################################

local methods = {
    -- miscellaneous commands
    ping    = {
        'PING', _send_inline, function(response) 
            if response == 'PONG' then return true else return false end
        end
    }, 
    echo    = { 'ECHO', _send_bulk }, 

    -- connection handling
    -- TODO: quit throws an error trying to read from a closed socket
    quit    = { 'QUIT' }, 

    -- commands operating on string values
    set             = { 'SET', _send_bulk }, 
    set_preserve    = { 'SETNX', _send_bulk, toboolean }, 
    get             = { 'GET' }, 
    get_multiple    = { 'MGET' }, 
    increment       = { 'INCR' }, 
    increment_by    = { 'INCRBY' }, 
    decrement       = { 'DECR' }, 
    decrement_by    = { 'DECRBY' }, 
    exists          = { 'EXISTS', _send_inline, toboolean }, 
    delete          = { 'DEL', _send_inline, toboolean }, 
    type            = { 'TYPE' }, 

    -- commands operating on the key space
    keys            = { 
        'KEYS',  _send_inline, function(response) 
            -- TODO: keys should return an array of keys (split the string by " ")
            return response
        end
    },
    random_key      = { 'RANDOMKEY' }, 
    rename          = { 'RENAME' }, 
    rename_preserve = { 'RENAMENX' }, 
    database_size   = { 'DBSIZE' }, 

    -- commands operating on lists
    push_tail   = { 'RPUSH', _send_bulk }, 
    push_head   = { 'LPUSH', _send_bulk }, 
    list_length = { 'LLEN' }, 
    list_range  = { 'LRANGE' }, 
    list_trim   = { 'LTRIM' }, 
    list_index  = { 'LINDEX' }, 
    list_set    = { 'LSET', _send_bulk }, 
    list_remove = { 'LREM', _send_bulk }, 
    pop_first   = { 'LPOP' }, 
    pop_last    = { 'RPOP' }, 

    -- commands operating on sets
    set_add                = { 'SADD' }, 
    set_remove             = { 'SREM' }, 
    set_cardinality        = { 'SCARD' }, 
    set_is_member          = { 'SISMEMBER' }, 
    set_intersection       = { 'SINTER' }, 
    set_intersection_store = { 'SINTER' }, 
    set_members            = { 'SMEMBERS' }, 

    -- multiple databases handling commands
    select_database = { 'SELECT' }, 
    move_key        = { 'MOVE' }, 
    flush_database  = { 'FLUSHDB' }, 
    flush_databases = { 'FLUSHALL' }, 

    -- sorting
    -- TODO: sort parameters as a table?
    sort    = { 'SORT', _send_inline }, 

    -- persistence control commands
    save            = { 'SAVE' }, 
    background_save = { 'BGSAVE' }, 
    last_save       = { 'LASTSAVE' }, 
    -- TODO: specs says that redis replies with a status code on error, 
    -- but we are closing the connection soon after having sent the command.
    shutdown        = { 'SHUTDOWN' }, 

    -- remote server control commands
    info    = { 
        'INFO', _send_inline, function(response) 
            local info = {}
            response:gsub('([^\r\n]*)\r\n', function(kv) 
                local k,v = kv:match(('([^:]*):([^:]*)'):rep(1))
                info[k] = v
            end)
            return info
        end
    },
}

function connect(host, port)
    local client_socket = socket.connect(host, port)

    if not client_socket then
        error('Could not connect to ' .. host .. ':' .. port)
    end

    local redis_client = {
        socket  = client_socket, 
        raw_cmd = function(self, buffer)
            return _send_raw(self, buffer .. protocol.newline)
        end, 
    }

    return setmetatable(redis_client, {
        __index = function(self, method)
            local redis_meth = methods[method]
            if redis_meth ~= nil then
                return function(self, ...) 
                    if redis_meth[2] == nil then 
                        table.insert(redis_meth, 2, _send_inline)
                    end

                    local response = redis_meth[2](self, methods[method][1], ...)
                    if redis_meth[3] ~= nil then
                        return redis_meth[3](response)
                    else
                        return response
                    end
                end
            end
        end
    })
end
