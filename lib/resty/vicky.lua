-- project: vicky
-- desc: Application for openresty 
-- version: 0.1
-- author: rockson zeta
-- 

local setmetatable = setmetatable
local string_sub = string.sub
local string_lower = string.lower
local string_find = string.find
local string_byte = string.byte
local string_gsub = string.gsub
local table_insert = table.insert
local ngx_var = ngx.var
local ngx_req = ngx.req
local ngx_re_match = ngx.re.match


local METHODS = {
    get = true,
    post = true,
    put= true,
    delete= true,
    patch= true,
    options= true,
    head= true,
    trace= true,
    all =true       -- means ignore request method
}

local _M = {_VERSION = "0.1"}
function _M:new() 
    local o = {
        -- request filters format: {{handle=fn,method=method,pattern=pattern}}
        filters = {},
        -- request direct handles format: {{handle=fn,method=method path}}
        handles = {},
        -- request expreg handles format: {{handle=fn,method=method,pattern=pattern}}
        ex_handles = {},
        -- if not handle find this function will be called at last if not nil
        unhandle = function() ngx.exit(404) end,
        -- if handle encount an exeption ,error_handle will be called
        error_handle = function()end
    }
    setmetatable(o,self)
    self.__index = self
    self:set_methods()
    return o

end

-- request key using method and path
function _M.method_path(method , path)
    if #path>1 and '/' == string_sub(path , -1) then
        path = string_sub(path,1,#path-1)
    end
    return string_lower(method)..' '..string_lower(path)
end

-- eg. /user/:id -> ^/user/(?<id>\w+)$
function _M.trans_named_path(path)
    local new_path = '^'..string_gsub(path,":%w+" , function(n) return '(?<'..string_sub(n ,2)..'>\\w+)'  end)..'$'
    --ngx.log(ngx.ERR ,path," -> ",new_path)
    return new_path
end

function _M:set_methods()
    for m,_ in pairs(METHODS) do
        local method = string_lower(m);
        self[method] = function(self,path,fn)
            --ngx.log(ngx.ERR, 'add '.. self.method_path(method,path))
            path = string_lower(path)
            if string_byte('^') == string_byte(path) then   -- regexp path eg. ^/user/(\d)+/$
                table_insert(self.ex_handles,{handle=fn,method=method,pattern=path})
            elseif nil ~= string_find(path , ':') then      -- named path eg. /user/:id
                table_insert(self.ex_handles,{handle=fn,method=method,pattern=_M.trans_named_path(path)})
            else
                self.handles[self.method_path(method,path)] = fn    -- direct path eg /user/info
            end
        end
    end
end

-- add filter
function _M:use(...)
    local len = select('#',...)
    local method,pattern,filter = 'all','^.*$',nil
    if 1 == len then
        filter = ...
    elseif 2 == len then
        pattern,filter = ...
    elseif 3 ==len then
        method,pattern,filter = ...
    end
    if string_byte('/') == string_byte(pattern) and nil ~= string_find(pattern , ':') then
        pattern = self.trans_named_path(pattern)
    end
    if nil ~= self.filters[pattern] then
    
        table_insert(self.filters[pattern] , {handle=filter,method=method,pattern=pattern})
    else
        self.filters[pattern] = {}
        table_insert(self.filters[pattern] , {handle=filter,method=method,pattern=pattern})
    end
    -- table_insert(self.filters , {handle=filter,method=method,pattern=pattern})
end

-- find handle by method and path in _M.handles and _M.ex_handles
function _M:find_handle(method,path)
    local h = self.handles[self.method_path(method , path)] or self.handles[self.method_path("all" , path)]
    if nil~=h then 
        return h,nil
    end
    return self.match_method_path(method,path,self.ex_handles)
end

-- find handle by method and path in handles
-- @handles format {{handle=fn,method=method,pattern=pattern}}
-- @return handle,pathParams , if return nil, no matched
function _M.match_method_path(method,path,handles)
    if nil~= handles and 0 < #handles then
        local h,p
        for _,v in ipairs(handles) do
            h,p = _M.match_method_path_single(method, path , v)
            if nil~=h then
                return h,p
            end
        end
    end
end
-- if match success return handle,pathParams , if not match return nothing
function _M.match_method_path_single(method,path,handle)
    if handle.method == method or 'all' == handle.method then
        if nil ~= handle.pattern then 
            local p,e = ngx_re_match(path,handle.pattern)
            if e~=nil then
                ngx.log(ngx.ERR,e)
            elseif nil~=p then
                return handle.handle,p
            end
        end
    end
end
function _M:match_method_path_filters()
    local m = self.get_method()
    local u = self.get_uri()
    for k,v in pairs(self.filters) do
        local p,e = ngx_re_match(u,k)
        if e~=nil then
            ngx.log(ngx.ERR,e)
        elseif nil~=p then
            return v,p
        end
    end
end
-- execute filter stack and execute handle
function _M:do_filters(filters,params)
    if #filters >0 then
        local i = 1
        local l = #filters
        local m = self.get_method()
        local function next() 
            if i<= l then
                i = i+1
                local tf = filters[i-1]
                local h = tf.handle
                if tf.method == m or tf.method == "all" then
                    h(next,params)
                else
                    next()
                end
            end
        end
        next();
    end
end

function _M:exe_handle(handle , params)
    xpcall(handle,function(e) ngx.log(ngx.ERR, debug.traceback());if 'function' == type(self.error_handle) then self.error_handle(e) end end ,params)
end

-- handle the request
function _M:handle()
    local f,p = self:match_method_path_filters()

    if nil~=f then
        self:do_filters(f,p)
    end 
    local handle,pathParams= self:find_handle(self.get_method(), self.get_uri())
    if handle then
        -- self:do_filters(handle,pathParams)
        self:exe_handle(handle , pathParams)
    elseif nil == f then
        if nil~= self.unhandle then
            self:unhandle();
            return
        end
        ngx.exit(404)
    else
        ngx.exit(200)
    end
end

function _M.get_uri() 
    return string_lower(ngx_var.uri)
end
function _M.get_method() 
    return string_lower(ngx_req.get_method())
end

function _M.__newindex(t, k, v)
    local h = string_byte(k)
    if string_byte('/') == h then -- / handle
        t:all(k, v)
        return
    end
    if string_byte('*') == h then -- * all handle
        t:all(string_sub(k ,2), v)
        return
    end
    if string_byte('^') == h then -- * all handle
        t:all(k, v)
        return
    end
    if string_byte('@') == h then -- add filter eg. @ fn or @/path fn or @get /path
        if 1 == h then
            t.all(t,'^.*$',v)
            return
        end
        local mp = string_sub(k,2)
        local spIndex =string_find(mp,' ')
        if spIndex then
            local method = string_lower(string_sub(mp,1,spIndex-1))
            if METHODS[method] then
                t[method](t,string_lower(string_sub(mp,spIndex+1)),v)
            end
        else
            t.all(t,mp,v)
        end
        return
    end
    local i = string_find(k , ' ')

    if i then                   -- method handle
        local m = string_lower(string_sub(k , 1 , i-1))
        local p = string_lower(string_sub(k ,i+1))
        if METHODS[m] then 
            t[m](t, p , v)
        end
        return
    end


    ngx.log(ngx.ERR, 'discard AppMeta __newindex '.. k)
end

return _M