
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

-module(nmc_auxdaemon).
-behaviour(gen_auxdaemon).
-behaviour(gen_server).

-include("ecoinpool_workunit.hrl").
-include("btc_daemon_util.hrl").
-include("../ebitcoin/include/btc_protocol_records.hrl").

-export([start_link/2, get_aux_work/1, send_aux_pow/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    pool_type,
    url,
    auth,
    tag,
    coinbaser_config,
    
    ebtc_id,
    txtbl,
    worktbl,
    block_num,
    last_fetch,
    
    memorypool,
    
    aux_work
}).

%% ===================================================================
%% Gen_AuxDaemon API
%% ===================================================================

start_link(SubpoolId, Config) ->
    gen_server:start_link(?MODULE, [SubpoolId, Config], []).

get_aux_work(PID) ->
    gen_server:call(PID, get_aux_work, infinity).

send_aux_pow(PID, AuxHash, AuxPOW) ->
    gen_server:call(PID, {send_aux_pow, AuxHash, AuxPOW}, infinity).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    PoolType = proplists:get_value(pool_type, Config),
    log4erl:warn(daemon, "Bitcoin-~p AuxDaemon starting...", [PoolType]),
    
    {URL, Auth, CoinbaserConfig, FullTag, EBtcId} = btc_daemon_util:parse_config(Config, 8335),
    
    {StoredState, TxTbl, WorkTbl} = btc_daemon_util:load_or_create_state(SubpoolId, PoolType, true),
    State = state_from_stored_state(StoredState),
    
    btc_daemon_util:setup_blockchange_listener(EBtcId),
    
    ecoinpool_server:auxdaemon_ready(SubpoolId, ?MODULE, self()),
    
    {ok, State#state{subpool=SubpoolId, pool_type=PoolType, url=URL, auth=Auth, tag=FullTag, coinbaser_config=CoinbaserConfig, ebtc_id=EBtcId, txtbl=TxTbl, worktbl=WorkTbl}}.

handle_call(get_aux_work, _From, OldState) ->
    % Check if a new block must be fetched
    State = fetch_block_with_state(OldState),
    % Send reply
    case State#state.aux_work of
        undefined ->
            {reply, {error, <<"aux block could not be created">>}, State};
        Auxwork ->
            {reply, Auxwork, State}
    end;

handle_call({send_aux_pow, AuxHash, AuxPOW}, _From, State=#state{url=URL, auth=Auth, worktbl=WorkTbl, txtbl=TxTbl}) ->
    try
        {reply, btc_daemon_util:send_aux_result(AuxHash, AuxPOW, URL, Auth, WorkTbl, TxTbl), State}
    catch error:_ ->
        {reply, {error, <<"exception in btc_daemon_util:send_aux_result/6">>}, State}
    end;

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({ebitcoin_blockchange, _, _, BlockNum}, State) ->
    {noreply, fetch_block_with_state(State#state{block_num={pushed, BlockNum + 1}})};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State) ->
    btc_daemon_util:flush_poll_daemon(),
    {noreply, fetch_block_with_state(State)};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State=#state{subpool=SubpoolId, pool_type=PoolType, txtbl=TxTbl, worktbl=WorkTbl}) ->
    % Store the last state
    StoredState = state_to_stored_state(State),
    btc_daemon_util:store_state(StoredState, SubpoolId, PoolType, TxTbl, WorkTbl, true),
    
    log4erl:warn(daemon, "Bitcoin-~p AuxDaemon terminated.", [PoolType]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

fetch_block_with_state(State) ->
    #state{
        subpool=SubpoolId,
        url=URL,
        auth=Auth,
        tag=Tag,
        coinbaser_config=CoinbaserConfig,
        block_num=OldBlockNum,
        last_fetch=LastFetch,
        ebtc_id=EBtcId,
        txtbl=TxTbl,
        worktbl=WorkTbl,
        memorypool=OldMemorypool,
        aux_work=OldAuxWork
    } = State,
    {BlockNum, Now, Memorypool, NewAuxWork} = btc_daemon_util:fetch_work(SubpoolId, URL, Auth, EBtcId, OldBlockNum, LastFetch, TxTbl, WorkTbl, OldMemorypool, OldAuxWork, ?MODULE),
    AuxWork = case NewAuxWork of
        undefined -> btc_daemon_util:make_auxwork(BlockNum, Memorypool, Tag, CoinbaserConfig, WorkTbl, fun ecoinpool_hash:dsha256_hash/1);
        _ -> NewAuxWork
    end,
    State#state{block_num=BlockNum, last_fetch=Now, memorypool=Memorypool, aux_work=AuxWork}.

state_from_stored_state(#stored_state{block_num=BlockNum, memorypool=Memorypool, aux_work=AuxWork}) ->
    #state{block_num=BlockNum, memorypool=Memorypool, aux_work=AuxWork}.

state_to_stored_state(#state{block_num=BlockNum, memorypool=Memorypool, aux_work=AuxWork}) ->
    #stored_state{block_num=BlockNum, memorypool=Memorypool, aux_work=AuxWork}.
