
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

-module(ecoinpool_server).
-behaviour(gen_server).

-include("ecoinpool_db_records.hrl").

-export([start_link/1, reconfigure/1]).

% Callbacks from ecoinpool_rpc
-export([rpc_request/4, rpc_lp_request/2]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    cdaemon_mod,
    cdaemon_pid,
    worktbl
}).

% Workunit record
-record(workunit, {
    id,
    worker
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Subpool=#subpool{id=Id, pool_type=PoolType}) ->
    % Derive the CoinDaemon module name from PoolType + "_coindaemon"
    CoinDaemonModule = list_to_atom(lists:concat([PoolType, "_coindaemon"])),
    gen_server:start_link({global, {subpool, Id}}, ?MODULE, [Subpool, CoinDaemonModule], []).

reconfigure(Subpool=#subpool{id=Id}) ->
    gen_server:cast({global, {subpool, Id}}, {reconfigure, Subpool}).

rpc_request(PID, Responder, Method, Params) ->
    gen_server:cast(PID, {rpc_request, Responder, Method, Params}).

rpc_lp_request(PID, Responder) ->
    gen_server:cast(PID, {rpc_lp_request, Responder}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([Subpool=#subpool{id=Id}, CoinDaemonModule]) ->
    io:format("Subpool ~p starting...~n", [Id]),
    % Trap exit
    process_flag(trap_exit, true),
    % Setup the work table
    WorkTbl = ets:new(worktbl, [set, protected, {keypos, 2}]),
    % Schedule CoinDaemon start
    gen_server:cast(self(), start_coindaemon),
    % Schedule RPC start
    gen_server:cast(self(), start_rpc),
    {ok, #state{subpool=Subpool, worktbl=WorkTbl, cdaemon_mod=CoinDaemonModule}}.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(start_coindaemon, State=#state{subpool=Subpool, cdaemon_mod=CoinDaemonModule}) ->
    % Extract CoinDaemon configuration
    #subpool{id=Id, coin_daemon_config=CoinDaemonConfig} = Subpool,
    % Register the CoinDaemon at our supervisor; terminate on failure
    {ok, CoinDaemon} = case ecoinpool_server_sup:start_coindaemon(Id, CoinDaemonModule, CoinDaemonConfig) of
        {ok, Pid, _} -> {ok, Pid};
        Other -> Other
    end,
    {noreply, State#state{cdaemon_pid=CoinDaemon}};

handle_cast(start_rpc, State=#state{subpool=#subpool{port=Port}}) ->
    % Start the RPC; terminate on failure
    ok = ecoinpool_rpc:start_rpc(Port, self()),
    {noreply, State};

handle_cast({reconfigure, _Subpool}, State=#state{}) ->
    {noreply, State};

handle_cast({rpc_request, Responder, _Method, _Params}, State=#state{}) ->
    Responder({ok, <<"test">>}),
    {noreply, State};

handle_cast({rpc_lp_request, _SubpoolId, _Responder}, State=#state{}) ->
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{subpool=#subpool{id=Id, port=Port}}) ->
    % Stop the RPC
    ecoinpool_rpc:stop_rpc(Port),
    % We don't need to stop the CoinDaemon, because that will be handled by the supervisor
    io:format("Subpool ~p terminated.~n", [Id]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
