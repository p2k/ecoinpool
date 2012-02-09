
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
    gen_server:call(?MODULE, {start_rpc, Port, SubpoolPID}, infinity).

stop_rpc(Port) ->
    gen_server:call(?MODULE, {stop_rpc, Port}, infinity).

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

send_greeting() ->
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    BinVSN = list_to_binary(VSN),
    self() ! {ok, <<"Welcome! This server is running ecoinpool v", BinVSN/binary, " by p2k. ",
        "You have reached one of the coin mining ports meant to be used with coin ",
        "mining software; consult the mining pool's homepage on how to setup a miner.">>, []}.

headers_from_options(Options) ->
    lists:foldl(
        fun
            (longpolling, AccHeaders) ->
                [{"X-Long-Polling", "/LP"} | AccHeaders];
            (rollntime, AccHeaders) ->
                [{"X-Roll-NTime", "expire=10"} | AccHeaders];
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

% Valid methods are defined here
parse_method(<<"getwork">>) -> getwork;
parse_method(<<"sc_getwork">>) -> sc_getwork;
parse_method(<<"sc_testwork">>) -> sc_testwork;
parse_method(<<"setup_user">>) -> setup_user;

parse_method(<<"">>) -> none;
parse_method(<<"test">>) -> test;
parse_method(_) -> unknown.

parse_path("/") ->
    {ok, false};
parse_path("/LP") ->
    {ok, true};
parse_path("/LP/") ->
    {ok, true};
parse_path(_) ->
    undefined.

parse_mining_extensions(SExtensions) ->
    lists:foldl(
        fun
            ("midstate", Acc) -> [midstate | Acc];
            ("rollntime", Acc) -> [rollntime | Acc];
            ("submitold", Acc) ->[submitold | Acc];
            (_, Acc) -> Acc
        end,
        [],
        SExtensions
    ).

handle_request(SubpoolPID, Req) ->
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    ServerName = "ecoinpool/" ++ VSN,
    case ecoinpool_jsonrpc:process_request(Req, ServerName, false) of
        {ok, Method, Params, ReqId, Auth, JSONP} ->
            MiningExtensions = case Req:get_header_value("X-Mining-Extensions") of
                undefined ->
                    [];
                SMiningExtensions ->
                    parse_mining_extensions(string:tokens(SMiningExtensions, " "))
            end,
            case parse_path(Req:get(path)) of
                {ok, true} -> % Ignore method and params on LP
                    ecoinpool_server:rpc_request(SubpoolPID, ecoinpool_rpc_request:new(self(), {Req:get(peer), Req:get_header_value("User-Agent")}, default, [], Auth, MiningExtensions, true));
                {ok, false} ->
                    case parse_method(Method) of
                        none ->
                            send_greeting();
                        unknown ->
                            self() ! {error, method_not_found};
                        AMethod ->
                            ecoinpool_server:rpc_request(SubpoolPID, ecoinpool_rpc_request:new(self(), {Req:get(peer), Req:get_header_value("User-Agent")}, AMethod, Params, Auth, MiningExtensions, false))
                    end;
                _ ->
                    self() ! {error, method_not_found}
            end,
            reply_loop(Req, ReqId, ServerName, JSONP);
        {error, _} ->
            error
    end.

reply_loop(Req, ReqId, ServerName, JSONP) ->
    % Block here, waiting for the result; also activate the socket to get close events
    Socket = Req:get(socket),
    mochiweb_socket:setopts(Socket, [{active, true}]),
    Peer = Req:get(peer),
    receive
        cancel ->
            ok;
        {error, Type} ->
            mochiweb_socket:setopts(Socket, [{active, false}]),
            ecoinpool_jsonrpc:respond_error(Req, Type, ReqId, ServerName, JSONP);
        {ok, Result, Options} ->
            mochiweb_socket:setopts(Socket, [{active, false}]),
            ecoinpool_jsonrpc:respond_success(Req, Result, ReqId, ServerName, JSONP, headers_from_options(Options));
        {start, WithHeartbeat, Options} ->
            Resp = ecoinpool_jsonrpc:respond_start_chunked(Req, ServerName, JSONP, headers_from_options(Options)),
            longpolling_loop(Resp, ReqId, WithHeartbeat, Socket, JSONP);
        {tcp_closed, Socket} ->
            log4erl:info("ecoinpool_rpc: Connection from ~s dropped unexpectedly.", [Peer]),
            mochiweb_socket:close(Socket),
            exit(normal)
    after
        300000 ->
            % Die after 5 minutes if nothing happened
            log4erl:info("ecoinpool_rpc: Dropping idle connection to ~s.", [Peer]),
            mochiweb_socket:close(Socket)
    end.

longpolling_loop(Resp, ReqId, WithHeartbeat, Socket, JSONP) ->
    receive
        {ok, Result, _} ->
            mochiweb_socket:setopts(Socket, [{active, false}]),
            ecoinpool_jsonrpc:respond_finish_chunked(Resp, Result, ReqId, JSONP);
        {error, Type} ->
            mochiweb_socket:setopts(Socket, [{active, false}]),
            ecoinpool_jsonrpc:respond_finish_chunked(Resp, {error, Type}, ReqId, JSONP);
        {tcp_closed, Socket} ->
            mochiweb_socket:close(Socket),
            exit(normal)
    after 300000 ->
        if
            WithHeartbeat ->
                % Send a newline character every 5 minutes to keep the connection alive
                Resp:write_chunk(<<10>>),
                longpolling_loop(Resp, ReqId, WithHeartbeat, Socket, JSONP);
            true ->
                mochiweb_socket:close(Socket)
        end
    end.
