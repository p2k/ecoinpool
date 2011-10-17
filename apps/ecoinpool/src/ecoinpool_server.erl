
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

-export([start_link/1]).

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

rpc_request(SubpoolId, Responder, Method, Params) ->
    gen_server:cast({global, {subpool, SubpoolId}}, {rpc_request, SubpoolId, Responder, Method, Params}).

rpc_lp_request(SubpoolId, Responder) ->
    gen_server:cast({global, {subpool, SubpoolId}}, {rpc_lp_request, SubpoolId, Responder}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([Subpool, CoinDaemonModule]) ->
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
    #subpool{id=Id, coin_daemon_host=Host, coin_daemon_port=Port, coin_daemon_user=User, coin_daemon_pass=Pass} = Subpool,
    % Register the CoinDaemon at the supervisor; terminate on failure
    {ok, CoinDaemon} = ecoinpool_sup:start_coindaemon(CoinDaemonModule, Id, Host, Port, User, Pass),
    {noreply, State#state{cdaemon_pid=CoinDaemon}};

handle_cast(start_rpc, State=#state{subpool=Subpool}) ->
    % Extract Subpool ID and RPC Port
    #subpool{id=Id, port=Port} = Subpool,
    % Start the RPC; terminate on failure
    {ok, _} = ecoinpool_rpc:start_rpc(Id, Port),
    {noreply, State};

handle_cast({rpc_request, _SubpoolId, _Responder, _Method, _Params}, State=#state{}) ->
    {noreply, State};

handle_cast({rpc_lp_request, _SubpoolId, _Responder}, State=#state{}) ->
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{subpool=Subpool, cdaemon_mod=CoinDaemonModule, cdaemon_pid=CoinDaemon}) ->
    #subpool{id=Id} = Subpool,
    % Stop the CoinDaemon, if running
    case CoinDaemon of
        undefined ->
            ok;
        _Pid ->
            ecoinpool_sup:stop_coindaemon(CoinDaemonModule, Id)
    end,
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
