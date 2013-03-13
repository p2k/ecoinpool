
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

-module(btc_coindaemon).
-behaviour(gen_coindaemon).
-behaviour(gen_server).

-include("ecoinpool_workunit.hrl").
-include("btc_daemon_util.hrl").
-include("../ebitcoin/include/btc_protocol_records.hrl").

-define(COINDAEMON_SUPPORTS_MM, true).
-include("gen_coindaemon_spec.hrl").

-export([
    start_link/2,
    getwork_method/0,
    sendwork_method/0,
    share_target/0,
    encode_workunit/2,
    analyze_result/1,
    make_reply/1,
    set_mmm/2,
    post_workunit/1,
    send_result/2,
    get_first_tx_with_branches/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    pool_type,
    url,
    auth,
    tag,
    coinbaser_config,
    
    mmm,
    
    ebtc_id,
    txtbl,
    worktbl,
    block_num,
    last_fetch,
    
    memorypool,
    coinbase_tx,
    
    aux_work
}).

%% ===================================================================
%% Gen_CoinDaemon API
%% ===================================================================

start_link(SubpoolId, Config) ->
    gen_server:start_link(?MODULE, [SubpoolId, Config], []).

getwork_method() ->
    getwork.

sendwork_method() ->
    getwork.

share_target() ->
    <<16#00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff:256>>.

encode_workunit(Workunit, MiningExtensions) ->
    btc_daemon_util:encode_workunit(Workunit, MiningExtensions, <<"ffffffffffffffffffffffffffffffffffffffffffffffffffffffff00000000">>).

analyze_result([Item]) ->
    btc_daemon_util:analyze_result(Item, fun ecoinpool_hash:dsha256_hash/1);
analyze_result(_) ->
    error.

make_reply([invalid]) ->
    false;
make_reply([_]) ->
    true.

set_mmm(PID, MMM) ->
    gen_server:cast(PID, {set_mmm, MMM}).

post_workunit(PID) ->
    gen_server:cast(PID, post_workunit).

send_result(PID, BData) ->
    gen_server:call(PID, {send_result, BData}, 30000).

get_first_tx_with_branches(PID, Workunit) ->
    gen_server:call(PID, {get_first_tx_with_branches, Workunit}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    PoolType = proplists:get_value(pool_type, Config),
    log4erl:warn(daemon, "Bitcoin-~p CoinDaemon starting...", [PoolType]),
    
    DefaultPort = case PoolType of
        btc -> 8332;
        nmc -> 8335
    end,
    {URL, Auth, CoinbaserConfig, FullTag, EBtcId} = btc_daemon_util:parse_config(Config, DefaultPort),
    
    {StoredState, TxTbl, WorkTbl} = btc_daemon_util:load_or_create_state(SubpoolId, PoolType, false),
    State = state_from_stored_state(StoredState),
    
    btc_daemon_util:setup_blockchange_listener(EBtcId),
    
    ecoinpool_server:coindaemon_ready(SubpoolId, self()),
    
    {ok, State#state{subpool=SubpoolId, pool_type=PoolType, url=URL, auth=Auth, tag=FullTag, coinbaser_config=CoinbaserConfig, ebtc_id=EBtcId, txtbl=TxTbl, worktbl=WorkTbl}}.

handle_call({send_result, BData}, _From, State=#state{url=URL, auth=Auth, worktbl=WorkTbl, txtbl=TxTbl}) ->
    {reply, btc_daemon_util:send_result(BData, URL, Auth, WorkTbl, TxTbl), State};

handle_call({get_first_tx_with_branches, #workunit{id=WorkunitId}}, _From, State=#state{worktbl=WorkTbl}) ->
    {reply, btc_daemon_util:get_first_tx_with_branches(WorkunitId, WorkTbl), State};

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({set_mmm, MMM}, State) ->
    {noreply, State#state{mmm=MMM}};

handle_cast(post_workunit, OldState) ->
    % Check if new work must be fetched
    State = fetch_work_with_state(OldState),
    % Extract state variables
    #state{subpool=SubpoolId, tag=Tag, coinbaser_config=CoinbaserConfig, worktbl=WorkTbl, block_num=BlockNum, memorypool=Memorypool, coinbase_tx=OldCoinbaseTx, aux_work=AuxWork} = State,
    % Make the new workunit
    {Workunit, CoinbaseTx} = btc_daemon_util:make_workunit(BlockNum, OldCoinbaseTx, Memorypool, Tag, CoinbaserConfig, AuxWork, WorkTbl),
    % Send back
    ecoinpool_server:store_workunit(SubpoolId, Workunit),
    % Update state
    {noreply, State#state{coinbase_tx=CoinbaseTx}};

handle_cast({ebitcoin_blockchange, _, _, BlockNum}, State) ->
    {noreply, fetch_work_with_state(State#state{block_num={pushed, BlockNum + 1}})};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State) ->
    btc_daemon_util:flush_poll_daemon(),
    {noreply, fetch_work_with_state(State)};

handle_info(retry_post_workunit, State) ->
    handle_cast(post_workunit, State);

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State=#state{subpool=SubpoolId, pool_type=PoolType, txtbl=TxTbl, worktbl=WorkTbl}) ->
    % Store the last state
    StoredState = state_to_stored_state(State),
    btc_daemon_util:store_state(StoredState, SubpoolId, PoolType, TxTbl, WorkTbl, false),
    
    log4erl:warn(daemon, "Bitcoin-~p CoinDaemon terminated.", [PoolType]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

fetch_work_with_state(State) ->
    #state{
        subpool=SubpoolId,
        url=URL,
        auth=Auth,
        block_num=OldBlockNum,
        last_fetch=LastFetch,
        ebtc_id=EBtcId,
        txtbl=TxTbl,
        worktbl=WorkTbl,
        memorypool=OldMemorypool,
        coinbase_tx=OldCoinbaseTx,
        mmm=MMM,
        aux_work=OldAuxWork
    } = State,
    {BlockNum, Now, Memorypool, CoinbaseTx} = btc_daemon_util:fetch_work(SubpoolId, URL, Auth, EBtcId, OldBlockNum, LastFetch, TxTbl, WorkTbl, OldMemorypool, OldCoinbaseTx, undefined),
    AuxWork = btc_daemon_util:fetch_aux_work(MMM, OldAuxWork),
    State#state{block_num=BlockNum, last_fetch=Now, memorypool=Memorypool, coinbase_tx=CoinbaseTx, aux_work=AuxWork}.

state_from_stored_state(#stored_state{block_num=BlockNum, memorypool=Memorypool, coinbase_tx=CoinbaseTx, aux_work=AuxWork}) ->
    #state{block_num=BlockNum, memorypool=Memorypool, coinbase_tx=CoinbaseTx, aux_work=AuxWork}.

state_to_stored_state(#state{block_num=BlockNum, memorypool=Memorypool, coinbase_tx=CoinbaseTx, aux_work=AuxWork}) ->
    #stored_state{block_num=BlockNum, memorypool=Memorypool, coinbase_tx=CoinbaseTx, aux_work=AuxWork}.
