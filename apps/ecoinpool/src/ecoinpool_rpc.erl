
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
            log4erl:warn("ecoinpool_rpc: Started RPC on port ~b", [Port]),
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
            log4erl:warn("ecoinpool_rpc: Stopped RPC on port ~b", [Port]),
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

default_headers() ->
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    S = {"Server", "ecoinpool/" ++ VSN},
    case get(jsonp) of
        undefined -> [S, {"Content-Type", "application/json"}];
        _ -> [S, {"Content-Type", "text/javascript"}, {"Access-Control-Allow-Origin", "*"}]
    end.

compose_success(ReqId, Result) ->
    Body = ejson:encode(
        {[
            {<<"result">>, Result},
            {<<"error">>, null},
            {<<"id">>, ReqId}
        ]}
    ),
    case get(jsonp) of
        undefined -> Body;
        Callback -> <<Callback/binary, $(, Body/binary, $), $;>>
    end.

headers_from_options(Options) ->
    lists:foldl(
        fun
            (longpolling, AccHeaders) ->
                [{"X-Long-Polling", "/LP"} | AccHeaders];
            ({reject_reason, Reason}, AccHeaders) ->
                [{"X-Reject-Reason", Reason} | AccHeaders];
            ({block_num, BlockNum}, AccHeaders) ->
                [{"X-Blocknum", BlockNum} | AccHeaders];
            (_, AccHeaders) ->
                AccHeaders
        end,
        [],
        Options
    ).

compose_error(ReqId, Type) ->
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
            {<<"result">>, null},
            {<<"error">>, {[
                {<<"code">>, RPCCode},
                {<<"message">>, RPCMessage}
            ]}},
            {<<"id">>, ReqId}
        ]}
    ),
    case get(jsonp) of
        undefined -> {HTTPCode, Body};
        Callback -> {HTTPCode, <<Callback/binary, $(, Body/binary, $), $;>>}
    end.

% Valid methods are defined here
parse_method(<<"getwork">>) -> getwork;
parse_method(<<"sc_getwork">>) -> sc_getwork;
parse_method(<<"sc_testwork">>) -> sc_testwork;
parse_method(<<"setup_user">>) -> setup_user;

parse_method(Other) when is_binary(Other) -> unknown;
parse_method(_) -> invalid.

parse_path("/") ->
    {ok, false};
parse_path("/LP") ->
    {ok, true};
parse_path(_) ->
    undefined.

handle_form_request(SubpoolPID, Req, Auth, Properties, LP) ->
    % Check for JSONP
    case proplists:get_value("callback", Properties) of
        undefined -> put(jsonp, undefined);
        Callback -> put(jsonp, list_to_binary(Callback))
    end,
    if
        LP -> % Ignore method and params on LP
            ecoinpool_server:rpc_request(SubpoolPID, ecoinpool_rpc_request:new(self(), {Req:get(peer), Req:get_header_value("User-Agent")}, default, [], Auth, true));
        true ->
            case parse_method(list_to_binary(proplists:get_value("method", Properties, ""))) of
                unknown ->
                    self() ! {error, method_not_found};
                invalid ->
                    self() ! {error, invalid_request};
                Method ->
                    BinParams = lists:map(fun list_to_binary/1, proplists:get_all_values("params[]", Properties)),
                    ecoinpool_server:rpc_request(SubpoolPID, ecoinpool_rpc_request:new(self(), {Req:get(peer), Req:get_header_value("User-Agent")}, Method, BinParams, Auth, false))
            end,
            % Return the request ID; if possible convert to integer else convert to binary
            ReqId = proplists:get_value("id", Properties, "1"),
            try
                list_to_integer(ReqId)
            catch
                error:_ -> list_to_binary(ReqId)
            end
    end.

% Note: this function returns the request ID (except if the connection is canceled)
handle_post(SubpoolPID, Req, Auth, LP) ->
    case Req:get_header_value("Content-Type") of
        Type when Type =:= "application/json"; Type =:= undefined ->
            put(jsonp, undefined),
            try
                case ejson:decode(Req:recv_body()) of % Decode JSON
                    {Properties} ->
                        case parse_method(proplists:get_value(<<"method">>, Properties)) of
                            unknown ->
                                self() ! {error, method_not_found};
                            invalid ->
                                self() ! {error, invalid_request};
                            Method ->
                                case proplists:get_value(<<"params">>, Properties, []) of
                                    Params when is_list(Params) ->
                                        ecoinpool_server:rpc_request(SubpoolPID, ecoinpool_rpc_request:new(self(), {Req:get(peer), Req:get_header_value("User-Agent")}, Method, Params, Auth, LP));
                                    _ ->
                                        self() ! {error, invalid_request}
                                end
                        end,
                        proplists:get_value(<<"id">>, Properties, 1);
                    _ ->
                        self() ! {error, invalid_request}, 1
                end
            catch _ ->
                self() ! {error, parse_error}, 1
            end;
        "application/x-www-form-urlencoded" ->
            try
                Properties = Req:parse_post(),
                handle_form_request(SubpoolPID, Req, Auth, Properties, LP)
            catch error:_ ->
                self() ! {error, parse_error}, 1
            end;
        _ ->
            Req:respond({415, [{"Content-Type", "text/plain"}], "Unsupported Content-Type. We only accept application/json and application/x-www-form-urlencoded."}),
            self() ! cancel, 1
    end.

handle_get(SubpoolPID, Req, Auth, LP) ->
    try
        Properties = Req:parse_qs(),
        handle_form_request(SubpoolPID, Req, Auth, Properties, LP)
    catch error:_ ->
        self() ! {error, parse_error}, 1
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
    ReqId = case Req:accepts_content_type("application/json") of
        true ->
            case parse_path(Req:get(path)) of
                {ok, LP} ->
                    case Req:get(method) of
                        'GET' ->
                            handle_get(SubpoolPID, Req, Auth, LP);
                        'POST' ->
                            handle_post(SubpoolPID, Req, Auth, LP);
                        _ ->
                            Req:respond({501, [{"Content-Type", "text/plain"}], "Unknown method"}),
                            self() ! cancel
                    end;
                _ ->
                    self() ! {error, method_not_found}, 1
            end;
        _ ->
            Req:respond({406, [{"Content-Type", "text/plain"}], "For this service you must accept application/json."}),
            self() ! cancel
    end,
    % Block here, waiting for the result
    receive
        cancel ->
            ok;
        {error, Type} ->
            {HTTPCode, Body} = compose_error(ReqId, Type),
            Req:respond({HTTPCode, default_headers(), Body});
        {ok, Result, Options} ->
            Body = compose_success(ReqId, Result),
            Headers = headers_from_options(Options),
            Req:respond({200, default_headers() ++ Headers, Body});
        {start, WithHeartbeat} ->
            Resp = Req:respond({200, default_headers(), chunked}),
            longpolling_loop(ReqId, Resp, WithHeartbeat)
    after
        300000 ->
            % Die after 5 minutes if nothing happened
            log4erl:info("ecoinpool_rpc: Dropping idle connection to ~s.", [Req:get(peer)]),
            mochiweb_socket:close(Req:get(socket))
    end.

longpolling_loop(ReqId, Resp, WithHeartbeat) ->
    receive
        {ok, Result, _} ->
            Body = compose_success(ReqId, Result),
            Resp:write_chunk(Body),
            Resp:write_chunk(<<>>);
        {error, Type} ->
            {_, Body} = compose_error(ReqId, Type),
            Resp:write_chunk(Body),
            Resp:write_chunk(<<>>)
    after 300000 ->
        if
            WithHeartbeat ->
                % Send a newline character every 5 minutes to keep the connection alive
                Resp:write_chunk(<<10>>),
                longpolling_loop(ReqId, Resp, WithHeartbeat);
            true ->
                Req = Resp:get(request),
                mochiweb_socket:close(Req:get(socket))
        end
    end.
