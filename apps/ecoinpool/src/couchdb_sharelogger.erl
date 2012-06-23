
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

-module(couchdb_sharelogger).
-behaviour(gen_sharelogger).
-behaviour(gen_server).

-include("gen_sharelogger_spec.hrl").

-export([start_link/2, log_share/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    subpool_id :: binary() | any,
    chain_logging :: main | aux | both,
    log_type :: round | interval | both,
    shares_db :: term(),
    cachetbl :: ets:tid(),
    cachetbln :: ets:tid(),
    next_update :: erlang:timestamp()
}).

-record(worker_last, {
    ip :: string(),
    user_agent :: string(),
    round :: integer() | undefined
}).

-record(subpool_last, {
    block_num :: integer() | undefined,
    prev_block :: binary() | undefined,
    target :: binary() | undefined,
    round :: integer() | undefined
}).

-record(entry, {
    id :: {binary(), main|aux} | {binary(), binary(), main|aux},
    valids = 0 :: integer(),
    invalids = 0 :: integer(),
    other_reasons = [] :: [{reject_reason(), integer()}],
    last :: #worker_last{} | #subpool_last{},
    timestamp :: erlang:timestamp()
}).

% This value cannot be changed at runtime, since it would mess up previous statistics
-define(LOG_INTERVAL, 10).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(LoggerId, Config) ->
    gen_server:start_link({local, LoggerId}, ?MODULE, Config, []).

log_share(LoggerId, Share) ->
    gen_server:cast(LoggerId, Share).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init(Config) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Load settings
    S = ecoinpool_db:get_couchdb_connection(),
    DatabaseName = binary_to_list(proplists:get_value(database, Config, <<"shares">>)),
    SubpoolId = proplists:get_value(subpool_id, Config, any),
    ChainLogging = case proplists:get_value(chain_logging, Config, <<"main">>) of
        <<"aux">> -> aux;
        <<"both">> -> both;
        _ -> main
    end,
    LogType = case proplists:get_value(log_type, Config, <<"both">>) of
        <<"round">> -> round;
        <<"interval">> -> interval;
        _ -> both
    end,
    % Create in-memory cache
    CacheTbl = ets:new(cachetbl, [set, protected, {keypos, #entry.id}]),
    CacheTblN = ets:new(cachetbln, [set, protected, {keypos, #entry.id}]),
    % Setup database
    {ok, SharesDB} = setup_shares_db(S, DatabaseName),
    % Setup interval logging
    NextUpdate = if LogType =:= interval; LogType =:= both ->
        % Start update timer
        timer:send_interval(5000, check_update), % Set to 5 seconds to allow some randomization and avoid possible update conflicts
        % Find next update time
        get_next_update_ts();
    true -> undefined end,
    {ok, #state{subpool_id=SubpoolId, chain_logging=ChainLogging, log_type=LogType, shares_db=SharesDB, cachetbl=CacheTbl, cachetbln=CacheTblN, next_update=NextUpdate}}.

handle_call(_, _From, State) ->
    {reply, error, State}.

handle_cast(#share{
        timestamp=Timestamp,
        server_id=local,
        
        subpool_id=SubpoolId,
        worker_id=WorkerId,
        user_id=UserId,
        ip=IP,
        user_agent=UserAgent,
        
        state=State,
        reject_reason=RejectReason,
        hash=Hash,
        target=Target,
        block_num=BlockNum,
        prev_block=PrevBlock,
        round=Round,
        data=Data,
        
        auxpool_name=AuxpoolName,
        aux_state=AuxState,
        aux_hash=AuxHash,
        aux_target=AuxTarget,
        aux_block_num=AuxBlockNum,
        aux_prev_block=AuxPrevBlock,
        aux_round=AuxRound},
        
        SState=#state{
            subpool_id=FilterSubpoolId,
            chain_logging=ChainLogging,
            log_type=LogType,
            shares_db=SharesDB,
            cachetbl=CacheTbl,
            cachetbln=CacheTblN,
            next_update=NextUpdate
        }) when
            (SubpoolId =:= FilterSubpoolId) or (FilterSubpoolId =:= any) ->
    
    Tbl = case timer:now_diff(Timestamp, NextUpdate) of
        D when D < 0 -> CacheTbl;
        _ -> CacheTblN
    end,
    
    % Handle for main chain
    if ChainLogging =:= main; ChainLogging =:= both ->
        update_subpool(Tbl, SubpoolId, main, Timestamp, State, RejectReason, BlockNum, PrevBlock, Target, Round),
        update_worker(Tbl, SubpoolId, WorkerId, main, Timestamp, State, RejectReason, IP, UserAgent, Round);
    true -> ok end,
    % Handle for aux chain
    if (ChainLogging =:= aux) or (ChainLogging =:= both), AuxState =/= undefined ->
        AuxRejectReason = if AuxState =:= invalid, RejectReason =:= undefined -> stale; true -> RejectReason end,
        update_subpool(Tbl, SubpoolId, aux, Timestamp, AuxState, AuxRejectReason, AuxBlockNum, AuxPrevBlock, AuxTarget, AuxRound),
        update_worker(Tbl, SubpoolId, WorkerId, aux, Timestamp, AuxState, AuxRejectReason, IP, UserAgent, AuxRound);
    true -> ok end,
    {noreply, State};

handle_cast(#share{}, State) -> % Ignore other shares
    {noreply, State}.

handle_info(check_update, State) ->
    

handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

setup_shares_db(S, DatabaseName) ->
    case couchbeam:open_or_create_db(S, DatabaseName) of
        {ok, DB} ->
            lists:foreach(fun ecoinpool_db:check_design_doc/1, [
                {DB, "stats", "shares_db_stats.json"},
                {DB, "timed_stats", "shares_db_timed_stats.json"},
                {DB, "auth", "shares_db_auth.json"}
            ]),
            {ok, DB};
        {error, Error} ->
            log4erl:error(db, "shares_db - couchbeam:open_or_create_db/3 returned an error:~n~p", [Error]),
            error
    end.

get_next_update_ts() ->
    {Date, Time} = calendar:now_to_datetime(erlang:now()),
    Secs = calendar:time_to_seconds(Time),
    NextDateTime = case ecoinpool_util:ceiling(Secs / (60 * ?LOG_INTERVAL)) * (60 * ?LOG_INTERVAL) of
        86400 ->
            Days = calendar:date_to_gregorian_days(Date),
            {calendar:gregorian_days_to_date(Days + 1), {0,0,0}};
        NextSecs ->
            {Date, calendar:seconds_to_time(NextSecs)}
    end,
    calendar:datetime_to_now(NextDateTime).

update_subpool(Tbl, SubpoolId, Chain, Timestamp, State, RejectReason, BlockNum, PrevBlock, Target, Round) ->
    Entry = case ets:lookup(Tbl, {SubpoolId, Chain}) of
        [] -> #entry{id={SubpoolId, Chain}};
        [E] -> E
    end,
    SubpoolLast = update_subpool_last(Entry#entry.last, BlockNum, PrevBlock, Target, Round),
    ets:insert(Tbl, update_entry(Entry, Timestamp, State, RejectReason, SubpoolLast)).

update_worker(Tbl, SubpoolId, WorkerId, Chain, Timestamp, State, RejectReason, IP, UserAgent, Round) ->
    Entry = case ets:lookup(Tbl, {SubpoolId, WorkerId, Chain}) of
        [] -> #entry{id={SubpoolId, WorkerId, Chain}};
        [E] -> E
    end,
    WorkerLast = update_worker_last(Entry#entry.last, IP, UserAgent, Round),
    ets:insert(Tbl, update_entry(Entry, Timestamp, State, RejectReason, WorkerLast)).

update_entry(Entry=#entry{valids=Valids, invalids=Invalids}, Timestamp, State, RejectReason, Last) ->
    case State of
        invalid ->
            case RejectReason of
                stale ->
                    Entry#entry{
                        invalids=Invalids + 1,
                        last=Last,
                        timestamp=Timestamp
                    };
                _ ->
                    OtherReasons = Entry#entry.other_reasons,
                    OtherReasonCount = case lists:keyfind(RejectReason, 1, OtherReasons) of
                        false -> 0;
                        {_, C} -> C
                    end,
                    Entry#entry{
                        invalids=Invalids + 1,
                        other_reasons=lists:keystore(RejectReason, 1, OtherReasons, {RejectReason, OtherReasonCount + 1}),
                        last=Last,
                        timestamp=Timestamp
                    }
            end;
        _ -> % valid | candidate
            Entry#entry{
                valids=Valids + 1,
                last=Last,
                timestamp=Timestamp
            }
    end.

update_subpool_last(undefined, BlockNum, PrevBlock, Target, Round) ->
    #subpool_last{
        block_num=BlockNum,
        prev_block=PrevBlock,
        target=Target,
        round=Round
    };
update_subpool_last(#subpool_last{block_num=LastBlockNum, prev_block=LastPrevBlock, target=LastTarget, round=LastRound}, BlockNum, PrevBlock, Target, Round) ->
    #subpool_last{
        block_num=case BlockNum of undefined -> LastBlockNum; _ -> BlockNum end,
        prev_block=case PrevBlock of undefined -> LastPrevBlock; _ -> PrevBlock end,
        target=case Target of undefined -> LastTarget; _ -> Target end,
        round=case Round of undefined -> LastRound; _ -> Round end
    }.

update_worker_last(undefined, IP, UserAgent, Round) ->
    #worker_last{
        ip=IP,
        user_agent=UserAgent,
        round=Round
    };
update_worker_last(#worker_last{ip=LastIP, user_agent=LastUserAgent, round=LastRound}, IP, UserAgent, Round) ->
    #worker_last{
        ip=case IP of undefined -> LastIP; _ -> IP end,
        user_agent=case UserAgent of undefined -> LastUserAgent; _ -> UserAgent end,
        round=case Round of undefined -> LastRound; _ -> Round end
    }.

-spec make_share_document(Timestamp :: erlang:timestamp(), WorkerId :: binary(), UserId :: term(), IP :: string(), UserAgent :: string(), State :: valid | candidate, Hash :: binary(), ParentHash :: binary() | undefined, Target :: binary(), BlockNum :: integer(), PrevBlock :: binary(), BData :: binary(), Round :: integer()) -> {[]}.
make_share_document(Timestamp, WorkerId, UserId, IP, UserAgent, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:now_to_datetime(Timestamp),
    filter_undefined({[
        {<<"worker_id">>, WorkerId},
        {<<"user_id">>, UserId},
        {<<"ip">>, binary:list_to_bin(IP)},
        {<<"user_agent">>, apply_if_defined(UserAgent, fun binary:list_to_bin/1)},
        {<<"timestamp">>, [YR,MH,DY,HR,ME,SD]},
        {<<"state">>, case State of valid -> <<"valid">>; candidate -> <<"candidate">> end},
        {<<"hash">>, ecoinpool_util:bin_to_hexbin(Hash)},
        {<<"parent_hash">>, apply_if_defined(ParentHash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"target">>, ecoinpool_util:bin_to_hexbin(Target)},
        {<<"block_num">>, BlockNum},
        {<<"prev_block">>, apply_if_defined(PrevBlock, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"round">>, Round},
        {<<"data">>, case State of valid -> undefined; candidate -> base64:encode(BData) end}
    ]}).

-spec make_reject_share_document(Timestamp :: erlang:timestamp(), WorkerId :: binary(), UserId :: term(), IP :: string(), UserAgent :: string(), Reason :: reject_reason(), Hash :: binary() | undefined, ParentHash :: binary() | undefined, Target :: binary() | undefined, BlockNum :: integer() | undefined, PrevBlock :: binary() | undefined, Round :: integer()) -> {[]}.
make_reject_share_document(Timestamp, WorkerId, UserId, IP, UserAgent, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:now_to_datetime(Timestamp),
    filter_undefined({[
        {<<"worker_id">>, WorkerId},
        {<<"user_id">>, UserId},
        {<<"ip">>, binary:list_to_bin(IP)},
        {<<"user_agent">>, apply_if_defined(UserAgent, fun binary:list_to_bin/1)},
        {<<"timestamp">>, [YR,MH,DY,HR,ME,SD]},
        {<<"state">>, <<"invalid">>},
        {<<"reject_reason">>, atom_to_binary(Reason, latin1)},
        {<<"hash">>, apply_if_defined(Hash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"parent_hash">>, apply_if_defined(ParentHash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"target">>, apply_if_defined(Target, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"block_num">>, BlockNum},
        {<<"prev_block">>, apply_if_defined(PrevBlock, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"round">>, Round}
    ]}).

apply_if_defined(undefined, _) ->
    undefined;
apply_if_defined(Value, Fun) ->
    Fun(Value).

filter_undefined({DocProps}) ->
    {lists:filter(fun ({_, undefined}) -> false; (_) -> true end, DocProps)}.

store_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round, DB) ->
    Doc = make_share_document(Timestamp, WorkerId, UserId, IP, UserAgent, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round),
    try
        couchbeam:save_doc(DB, Doc),
        ok
    catch error:Reason ->
        log4erl:warn(db, "store_share_in_db: ignored error:~n~p", [Reason]),
        error
    end.

store_invalid_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round, DB) ->
    Doc = make_reject_share_document(Timestamp, WorkerId, UserId, IP, UserAgent, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round),
    try
        couchbeam:save_doc(DB, Doc),
        ok
    catch error:Reason ->
        log4erl:warn(db, "store_invalid_share_in_db: ignored error:~n~p", [Reason]),
        error
    end.
