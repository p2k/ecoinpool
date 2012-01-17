
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

-module(mysql_sharelogger).
-behaviour(gen_event).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-record(my_share, {
    time :: calendar:datetime(),
    rem_host :: binary(),
    username :: binary(),
    our_result :: integer(),
    our_result_bitcoin :: integer(),
    our_result_namecoin = 0 :: integer(),
    upstream_result :: integer(),
    reason :: binary() | undefined,
    source :: string(),
    solution :: binary() | undefined,
    block_num :: binary() | undefined,
    prev_block_hash :: binary() | undefined,
    useragent :: binary()
}).
-type my_share() :: #my_share{}.

-type main_q_entry() :: {WorkerId :: binary(), Hash :: binary(), Share :: my_share()}.
-type aux_q_entry() :: {WorkerId :: binary(), ParentHash :: binary(), Seq :: integer(), State :: invalid | valid | candidate, Solution :: binary() | undefined}.

% Internal state record
-record(state, {
    my_pool_id :: atom(),
    table :: string(),
    log_remote :: boolean(),
    subpool_id :: binary() | any,
    log_type :: main | aux | both,
    commit_timer :: timer:tref() | undefined,
    always_log_data :: boolean(),
    
    main_q :: [main_q_entry()] | undefined,
    aux_q :: [aux_q_entry()] | undefined,
    my_shares = [] :: [my_share()],
    conv_ts :: fun((erlang:timestamp()) -> calendar:datetime()),
    insert_stmt_head :: binary(),
    insert_field_ids :: [integer()]
}).

%% ===================================================================
%% Gen_Event callbacks
%% ===================================================================

init(Options) ->
    % Load settings
    Host = binary_to_list(proplists:get_value(host, Options, <<"localhost">>)),
    Port = proplists:get_value(port, Options, 3306),
    Database = binary_to_list(proplists:get_value(database, Options, <<"ecoinpool">>)),
    User = binary_to_list(proplists:get_value(user, Options, <<"root">>)),
    Pass = binary_to_list(ecoinpool_util:parse_json_password(proplists:get_value(pass, Options, <<"mysql">>))),
    Table = proplists:get_value(table, Options, <<"shares">>),
    LogRemote = proplists:get_value(log_remote, Options, false),
    SubpoolId = proplists:get_value(subpool_id, Options, any),
    LogType = case proplists:get_value(log_type, Options, <<"main">>) of
        <<"aux">> -> aux;
        <<"both">> -> both;
        _ -> main
    end,
    CommitInterval = proplists:get_value(commit_interval, Options, 15),
    AlwaysLogData = proplists:get_value(always_log_data, Options, false),
    % Start MySQL connection
    {ok, MyPoolId} = ecoinpool_sup:start_mysql(Host, Port, User, Pass, Database),
    % Check available columns
    {data, MyFieldsResult} = mysql:fetch(MyPoolId, ["SHOW COLUMNS FROM `", Table, "`;"]),
    MyFieldNames = [FName || {FName, _, _, _, _, _} <- mysql:get_result_rows(MyFieldsResult)],
    {InsertFieldNames, InsertFieldIds} = lists:foldr(
        fun (N, {IFN, IFI}) ->
            I = case N of
                <<"time">> -> #my_share.time;
                <<"rem_host">> -> #my_share.rem_host;
                <<"username">> -> #my_share.username;
                <<"our_result">> -> #my_share.our_result;
                <<"our_result_bitcoin">> when LogType =:= both -> #my_share.our_result_bitcoin;
                <<"our_result_namecoin">> when LogType =:= both -> #my_share.our_result_namecoin;
                <<"upstream_result">> -> #my_share.upstream_result;
                <<"reason">> -> #my_share.reason;
                <<"source">> -> #my_share.source;
                <<"solution">> -> #my_share.solution;
                <<"block_num">> -> #my_share.block_num;
                <<"prev_block_hash">> -> #my_share.prev_block_hash;
                <<"useragent">> -> #my_share.useragent;
                _ -> 0
            end,
            if
                I > 0 -> {[[$`, N, $`] | IFN], [I | IFI]};
                true -> {IFN, IFI}
            end
        end,
        {[], []},
        MyFieldNames
    ),
    InsertStmtHead = iolist_to_binary(["INSERT INTO `", Table, "` (", string:join(InsertFieldNames, ", "), ") VALUES\n"]),
    % Get the server's time difference to UTC and setup the timestamp converter
    {data, TimeDiffResult} = mysql:fetch(MyPoolId, <<"SELECT TIMEDIFF(NOW(), UTC_TIMESTAMP());">>),
    [{TimeDiff}] = mysql:get_result_rows(TimeDiffResult),
    ConvTS = make_timestamp_converter(TimeDiff),
    % Setup commit timer
    CommitTimer = if
        not is_integer(CommitInterval); CommitInterval =< 0 ->
            undefined;
        true ->
            {ok, T} = timer:apply_interval(CommitInterval * 1000, gen_event, call, [ecoinpool_share_broker, {?MODULE, proplists:get_value(id, Options)}, insert_my_shares]),
            T
    end,
    {ok, #state{
        my_pool_id = MyPoolId,
        table = Table,
        log_remote = LogRemote,
        subpool_id = SubpoolId,
        log_type = LogType,
        commit_timer = CommitTimer,
        always_log_data = AlwaysLogData,
        main_q = case LogType of both -> []; _ -> undefined end,
        aux_q = case LogType of both -> []; _ -> undefined end,
        conv_ts = ConvTS,
        insert_stmt_head = InsertStmtHead,
        insert_field_ids = InsertFieldIds
    }}.

handle_event(#subpool{}, State) ->
    {ok, State};

handle_event(Share=#share{subpool_id=SubpoolId, is_aux=IsAux, is_local=IsLocal}, State=#state{log_remote=LogRemote, subpool_id=FilterSubpoolId, log_type=LogType, commit_timer=CommitTimer})
        when IsLocal or LogRemote,
             (SubpoolId =:= FilterSubpoolId) or (FilterSubpoolId =:= any),
             not IsAux or (LogType =/= main) ->
    if
        not IsAux or (LogType =:= aux) ->
            State1 = handle_main_share(Share, State),
            case CommitTimer of
                undefined ->
                    {ok, ok, State2} = handle_call(insert_my_shares, State1),
                    {ok, State2};
                _ ->
                    {ok, State1}
            end;
        LogType =:= both ->
            State1 = handle_aux_share(Share, State),
            case CommitTimer of
                undefined ->
                    {ok, ok, State2} = handle_call(insert_my_shares, State1),
                    {ok, State2};
                _ ->
                    {ok, State1}
            end;
        true ->
            {ok, State}
    end;

handle_event(_, State) ->
    {ok, State}.

handle_call(insert_my_shares, State=#state{my_shares=[]}) ->
    {ok, ok, State};
handle_call(insert_my_shares, State=#state{my_shares=MyShares, my_pool_id=MyPoolId, insert_stmt_head=InsertStmtHead, insert_field_ids=InsertFieldIds}) ->
    insert_my_shares(MyPoolId, lists:reverse(MyShares), InsertStmtHead, InsertFieldIds),
    {ok, ok, State#state{my_shares=[]}};

handle_call(_, State) ->
    {ok, error, State}.

handle_info(_, State) ->
    {ok, State}.

terminate(_Reason, State=#state{commit_timer=CommitTimer}) ->
    case CommitTimer of
        undefined ->
            ok;
        _ ->
            timer:cancel(CommitTimer),
            handle_call(insert_my_shares, State) % Flush remaining shares
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

handle_main_share(Share, State=#state{always_log_data=AlwaysLogData, main_q=MainQ, aux_q=AuxQ, my_shares=MyShares, conv_ts=ConvTS}) ->
    #share{
        timestamp=Timestamp,
        pool_name=PoolName,
        worker_id=WorkerId,
        worker_name=WorkerName,
        ip=IP,
        user_agent=UserAgent,
        state=ShareState,
        reject_reason=RejectReason,
        hash=Hash,
        block_num=IntBlockNum,
        prev_block=PrevBlock,
        data=Data
    } = Share,
    Time = ConvTS(Timestamp),
    OurResult = case ShareState of invalid -> 0; _ -> 1 end,
    Solution = if
        AlwaysLogData, Data =/= undefined; ShareState =:= candidate, Data =/= undefined ->
            ecoinpool_util:bin_to_hexbin(Data);
        true ->
            undefined
    end,
    BlockNum = case IntBlockNum of
        undefined -> undefined;
        IntBlockNum -> list_to_binary(integer_to_list(IntBlockNum))
    end,
    S = #my_share{
        time = Time,
        rem_host = IP,
        username = WorkerName,
        our_result = OurResult,
        our_result_bitcoin = OurResult,
        upstream_result = case ShareState of candidate -> 1; _ -> 0 end,
        reason = case RejectReason of undefined -> undefined; _ -> atom_to_binary(RejectReason, utf8) end,
        source = PoolName,
        solution = Solution,
        block_num = BlockNum,
        prev_block_hash = if is_binary(PrevBlock) -> ecoinpool_util:bin_to_hexbin(PrevBlock); true -> undefined end,
        useragent = UserAgent
    },
    {NewMainQ, NewAuxQ, NewMyShares} = if
        is_binary(Hash), is_list(MainQ), is_list(AuxQ) ->
            check_share_queues(MainQ ++ [{WorkerId, Hash, S}], AuxQ, MyShares);
        true ->
            {MainQ, AuxQ, [S | MyShares]}
    end,
    State#state{main_q=NewMainQ, aux_q=NewAuxQ, my_shares=NewMyShares}.

handle_aux_share(#share{worker_id=WorkerId, state=ShareState, parent_hash=ParentHash, data=Data}, State=#state{main_q=MainQ, aux_q=AuxQ, my_shares=MyShares}) ->
    {NewMainQ, NewAuxQ, NewMyShares} = if
        is_binary(ParentHash), is_list(MainQ), is_list(AuxQ) ->
            Solution = case ShareState of
                candidate when Data =/= undefined -> ecoinpool_util:bin_to_hexbin(Data);
                _ -> undefined
            end,
            check_share_queues(MainQ, AuxQ ++ [{WorkerId, ParentHash, ShareState, Solution}], MyShares);
        true ->
            {MainQ, AuxQ, MyShares}
    end,
    State#state{main_q=NewMainQ, aux_q=NewAuxQ, my_shares=NewMyShares}.

-spec check_share_queues(MainQ :: [main_q_entry()], AuxQ :: [aux_q_entry()], MyShares :: [my_share()]) -> {[main_q_entry()], [aux_q_entry()], [my_share()]}.
check_share_queues(MainQ=[], AuxQ, MyShares) ->
    {MainQ, AuxQ, MyShares};
check_share_queues(MainQ, AuxQ=[], MyShares) ->
    {MainQ, AuxQ, MyShares};
check_share_queues(MainQ=[{WorkerId, Hash, S} | MainQT], AuxQ, MyShares) ->
    CleanedAuxQ = lists:dropwhile(
        fun ({AuxWorkerId, ParentHash, _, _}) ->
            (AuxWorkerId =/= WorkerId) orelse (ParentHash =/= Hash)
        end,
        AuxQ
    ),
    case CleanedAuxQ of
        [] ->
            % Check if later main hashes correlate to aux hashes
            HasLaterCorrelations = lists:any(
                fun ({OtherWorkerId, OtherHash, _}) ->
                    lists:any(
                        fun ({AuxWorkerId, ParentHash, _, _}) ->
                            (AuxWorkerId =:= OtherWorkerId) andalso (ParentHash =:= OtherHash)
                        end,
                        AuxQ
                    )
                end,
                MainQT
            ),
            case HasLaterCorrelations of
                false -> % No later correlations, we have to wait
                    {MainQ, AuxQ, MyShares};
                true -> % Later correlation found, this main share must be stale
                    log4erl:warn("mysql_sharelogger: Detected a stale main share!"),
                    check_share_queues(MainQT, AuxQ, [S | MyShares])
            end;
        [{WorkerId, Hash, AuxState, AuxSolution} | AuxQT] ->
            if
                length(AuxQT) < length(AuxQ) - 1 ->
                    log4erl:warn("mysql_sharelogger: Dropped ~b non-correlating aux share(s).", [length(AuxQ) - 1 - length(AuxQT)]);
                true ->
                    ok
            end,
            FullS = case AuxState of
                candidate ->
                    S#my_share{our_result_namecoin=1, upstream_result=1, solution=AuxSolution};
                valid ->
                    S#my_share{our_result_namecoin=1};
                invalid when S#my_share.our_result_bitcoin =:= 1 ->
                    S#my_share{reason = <<"partial-stale">>};
                invalid ->
                    S
            end,
            check_share_queues(MainQT, AuxQT, [FullS | MyShares])
    end.

make_timestamp_converter({0,0,0}) ->
    fun calendar:now_to_datetime/1;
make_timestamp_converter(TimeDiff) ->
    TimeDiffSeconds = calendar:time_to_seconds(TimeDiff),
    fun (Now) ->
        DateTime = calendar:now_to_datetime(Now),
        S = calendar:datetime_to_gregorian_seconds(DateTime),
        calendar:gregorian_seconds_to_datetime(S + TimeDiffSeconds)
    end.

-spec insert_my_shares(MyPoolId :: atom(), MyShares :: [my_share()], InsertStmtHead :: binary(), InsertFieldIds :: [integer()]) -> ok | {error, term()}.
insert_my_shares(MyPoolId, MyShares, InsertStmtHead, InsertFieldIds) ->
    FullStmt = [InsertStmtHead, string:join([make_my_share_row(MyShare, InsertFieldIds) || MyShare <- MyShares], ",\n"), $;],
    case mysql:fetch(MyPoolId, FullStmt) of
        {updated, _} -> ok;
        {error, Error} -> log4erl:warn("Error while inserting shares: ~p", [Error]), {error, Error}
    end.

-spec make_my_share_row(MyShare :: my_share(), InsertFieldIds :: [integer()]) -> iolist().
make_my_share_row(MyShare, InsertFieldIds) ->
    Data = [mysql:encode(element(FieldId, MyShare)) || FieldId <- InsertFieldIds],
    [$(, string:join(Data, ", "), $)].
