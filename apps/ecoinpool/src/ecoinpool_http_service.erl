
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ecoinpool.
%%
%% ecoinpool is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ecoinpool is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ecoinpool_http_service).

-export([start/1, stop/0, handle_request/1]).

start(Port) ->
    Loop = fun (Req) -> ?MODULE:handle_request(Req) end,
    mochiweb_http:start([{name, ?MODULE}, {port, Port}, {loop, Loop}]).

stop() ->
    mochiweb_http:stop(?MODULE).

handle_request(Req) ->
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    ServerName = "ecoinpool/" ++ VSN,
    case Req:get(path) of
        "/rpc/" ->
            case ecoinpool_jsonrpc:process_request(Req, ServerName, true) of
                {ok, Method, Params, ReqId, Auth, JSONP} ->
                    try
                        Result = handle_rpc_request(Method, Params, Auth),
                        ecoinpool_jsonrpc:respond_success(Req, Result, ReqId, ServerName, JSONP)
                    catch error:Type ->
                        ecoinpool_jsonrpc:respond_error(Req, Type, ReqId, ServerName, JSONP) 
                    end;
                {error, _} ->
                    error
            end;
        _ ->
            Req:respond({404, [{"Server", ServerName}, {"Content-Type", "text/plain"}], "404 Not Found"}),
            error
    end.

handle_rpc_request(<<"encrypt_password">>, Params, _Auth) ->
    {Plain, Seed} = case Params of
        [P] when is_binary(P) -> {P, random};
        [P, S] when is_binary(P), is_binary(S) -> {P, S};
        _ -> error(invalid_request)
    end,
    ecoinpool_util:make_json_password(Plain, Seed);
handle_rpc_request(<<"get_api_version">>, Params, _Auth) ->
    case Params of
        [] -> ok;
        _ -> error(invalid_request)
    end,
    1;
handle_rpc_request(<<"validate_address">>, Params, _Auth) ->
    case Params of
        [Address] when is_binary(Address) ->
            try
                btc_protocol:hash160_from_address(Address),
                true
            catch error:_ ->
                false
            end;
        _ -> error(invalid_request)
    end;
handle_rpc_request(_, _, _) ->
    error(method_not_found).
