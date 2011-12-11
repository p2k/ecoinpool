
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ebitcoin.
%%
%% ebitcoin is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ebitcoin is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ebitcoin.  If not, see <http://www.gnu.org/licenses/>.
%%

% The "crash repository" stores data between module crashes to allow consistent
% operation. You typically use the terminate function of gen_server for that
% opportunity and check for data in the init function. Note that fetching will
% remove data from the repo.

-module(ebitcoin_crash_repo).
-behaviour(gen_server).

-export([
    start_link/1,
    store/3,
    fetch/2,
    transfer_ets/2
]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    kvstorage,
    etsstorage
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(ServerName) ->
    gen_server:start_link(ServerName, ?MODULE, [], []).

store(ServerRef, Key, Value) ->
    gen_server:cast(ServerRef, {store, Key, Value}).

fetch(ServerRef, Key) ->
    gen_server:call(ServerRef, {fetch, Key}).

transfer_ets(ServerRef, Key) ->
    gen_server:call(ServerRef, {transfer_ets, Key}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([]) ->
    {ok, #state{kvstorage=dict:new(), etsstorage=dict:new()}}.

handle_call({fetch, Key}, _From, State=#state{kvstorage=KVStorage}) ->
    case dict:find(Key, KVStorage) of
        {ok, Value} ->
            {reply, {ok, Value}, State#state{kvstorage=dict:erase(Key, KVStorage)}};
        error ->
            {reply, error, State}
    end;

handle_call({transfer_ets, Key}, {Pid, _}, State=#state{etsstorage=ETSStorage}) ->
    case dict:find(Key, ETSStorage) of
        {ok, Tab} ->
            ets:give_away(Tab, Pid, Key),
            {reply, ok, State#state{etsstorage=dict:erase(Key, ETSStorage)}};
        error ->
            {reply, error, State}
    end;

handle_call(_Message, _From, State) ->
    {reply, {error, no_such_call}, State}.

handle_cast({store, Key, Value}, State=#state{kvstorage=KVStorage}) ->
    {noreply, State#state{kvstorage=dict:store(Key, Value, KVStorage)}};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'ETS-TRANSFER', Tab, _FromPid, Key}, State=#state{etsstorage=ETSStorage}) ->
    {noreply, State#state{etsstorage=dict:store(Key, Tab, ETSStorage)}};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
