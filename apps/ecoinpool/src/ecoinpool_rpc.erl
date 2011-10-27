
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

-module(ecoinpool_rpc).
-behaviour(gen_server).

-export([start_link/0, start_rpc/2, stop_rpc/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Export to allow code change; do not call yourself
-export([handle_request/2]).

-record(server, {
    port,
    name,
    pid
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_rpc(Port, SubpoolPID) ->
    gen_server:call(?MODULE, {start_rpc, Port, SubpoolPID}).

stop_rpc(Port) ->
    gen_server:call(?MODULE, {stop_rpc, Port}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([]) ->
    {ok, dict:new()}.

handle_call({start_rpc, Port, SubpoolPID}, _From, Servers) ->
    % Check if port occupied
    case dict:is_key(Port, Servers) of
        false ->
            % Create name
            Name = list_to_atom(lists:concat([ecoinpool_rpc_, Port])),
            % Build server record
            Srv = #server{port=Port, name=Name, pid=SubpoolPID},
            % Create loop function
            Loop = fun (Req) -> ?MODULE:handle_request(SubpoolPID, Req) end,
            % Launch server
            mochiweb_http:start([{name, Name}, {port, Port}, {loop, Loop}]),
            % Store and reply
            io:format("Started RPC on port ~p~n", [Port]),
            {reply, ok, dict:store(Port, Srv, Servers)};
        _ ->
            {reply, {error, port_occupied}, Servers}
    end;

handle_call({stop_rpc, Port}, _From, Servers) ->
    case dict:find(Port, Servers) of
        {ok, #server{name=Name}} ->
            % Stop server
            mochiweb_http:stop(Name),
            % Remove and reply
            io:format("Stopped RPC on port ~p~n", [Port]),
            {reply, ok, dict:erase(Port, Servers)};
        _ ->
            {reply, {error, not_running}, Servers}
    end;

handle_call(_Message, _From, Servers) ->
    {reply, error, Servers}.

handle_cast(_Message, Servers) ->
    {noreply, Servers}.

handle_info(_Message, Servers) ->
    {noreply, Servers}.

terminate(_Reason, _Servers) ->
    ok.

code_change(_OldVersion, Servers, _Extra) ->
    {ok, Servers}.

%% ===================================================================
%% Internal functions
%% ===================================================================

server_header() ->
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    {"Server", "ecoinpool/" ++ VSN}.

respond_success(Req, ReqId, Result, Options) ->
    % Make JSON reply
    Body = ejson:encode(
        {[
            {result, Result},
            {error, null},
            {id, ReqId}
        ]}
    ),
    % Create headers from options
    Headers = lists:foldl(
        fun (Option, AccHeaders) ->
            case Option of
                longpolling -> [{"X-Long-Polling", "/LP"} | AccHeaders];
                _ -> AccHeaders
            end
        end,
        [],
        Options
    ),
    Req:respond({200, [server_header(), {"Content-Type", "application/json"} | Headers], Body}).

respond_error(Req, ReqId, Type) ->
    {HTTPCode, RPCCode, RPCMessage} = case Type of
        parse_error -> {500, -32700, <<"Parse error">>};
        invalid_request -> {400, -32600, <<"Invalid request">>};
        method_not_found -> {404, -32601, <<"Method not found">>};
        invalid_method_params -> {400, -32602, <<"Invalid parameters">>};
        authorization_required -> {401, -32001, <<"Authorization required">>};
        permission_denied -> {403, -32002, <<"Permission denied">>};
        {CustomCode, CustomMessage} when is_integer(CustomCode) ->
            BinCustomMessage = if
                is_binary(CustomMessage) -> CustomMessage;
                is_list(CustomMessage) -> list_to_binary(CustomMessage);
                true -> list_to_binary(io_lib:print(CustomMessage))
            end,
            {500, CustomCode, BinCustomMessage};
        _ -> {500, -32603, <<"Internal error">>}
    end,
    Body = ejson:encode(
        {[
            {result, null},
            {error, {[
                {code, RPCCode},
                {message, RPCMessage}
            ]}},
            {id, ReqId}
        ]}
    ),
    Req:respond({HTTPCode, [server_header(), {"Content-Type", "application/json"}], Body}).

respond_error(Req, Type) ->
    respond_error(Req, 1, Type).

make_responder(Req, ReqId) ->
    fun
        ({ok, Result}) -> respond_success(Req, ReqId, Result, []);
        ({ok, Result, Options}) -> respond_success(Req, ReqId, Result, Options);
        ({error, Type}) -> respond_error(Req, ReqId, Type)
    end.

make_responder(Req) ->
    make_responder(Req, 1).

% Valid methods are defined here
parse_method(<<"getwork">>) -> getwork;
parse_method(<<"sc_getwork">>) -> sc_getwork;
parse_method(<<"sc_testwork">>) -> sc_testwork;

parse_method(Other) when is_binary(Other) -> unknown;
parse_method(_) -> invalid.

handle_post(SubpoolPID, Req, Auth) ->
    case Req:get_header_value("Content-Type") of
        Type when Type =:= "application/json"; Type =:= undefined ->
            try
                case ejson:decode(Req:recv_body()) of % Decode JSON
                    {Properties} ->
                        ReqId = proplists:get_value(<<"id">>, Properties, 1),
                        case parse_method(proplists:get_value(<<"method">>, Properties)) of
                            unknown ->
                                respond_error(Req, ReqId, method_not_found);
                            invalid ->
                                respond_error(Req, ReqId, invalid_request);
                            Method ->
                                case proplists:get_value(<<"params">>, Properties, []) of
                                    Params when is_list(Params) ->
                                        ecoinpool_server:rpc_request(SubpoolPID, make_responder(Req, ReqId), Method, Params, Auth);
                                    _ ->
                                        respond_error(Req, ReqId, invalid_request)
                                end
                        end;
                    _ ->
                        respond_error(Req, invalid_request)
                end
            catch _ ->
                respond_error(Req, parse_error)
            end;
        _ ->
            Req:respond({415, [{"Content-Type", "text/plain"}], "Unsupported Content-Type. We only accept application/json."})
    end.

handle_request(SubpoolPID, Req) ->
    Auth = case Req:get_header_value("Authorization") of
        "Basic " ++ BasicAuth ->
            try
                case binary:split(base64:decode(BasicAuth), <<":">>) of
                    [User, Pass] -> {User, Pass};
                    _ -> unauthorized
                end
            catch
                error:_ ->
                    unauthorized
            end;
        _ ->
            unauthorized
    end,
    case Req:accepts_content_type("application/json") of
        true ->
            case Req:get(method) of
                'GET' ->
                    case Req:get(path) of
                        "/" -> % Normal request - use default handler
                            ecoinpool_server:rpc_request(SubpoolPID, make_responder(Req), default, [], Auth);
                        "/LP" -> % Longpolling
                            ecoinpool_server:rpc_lp_request(SubpoolPID, make_responder(Req), Auth);
                        _ ->
                            respond_error(Req, method_not_found)
                    end;
                'POST' ->
                    handle_post(SubpoolPID, Req, Auth);
                _ ->
                    Req:respond({501, [], []}) % Unknown method
            end;
        _ ->
            Req:respond({406, [{"Content-Type", "text/plain"}], "For this service you must accept application/json."})
    end.
