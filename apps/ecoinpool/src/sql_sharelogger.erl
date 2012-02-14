
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

-module(sql_sharelogger).
-behaviour(gen_server).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(sql_share, {
    time :: calendar:datetime(),
    rem_host :: string(),
    username :: binary(),
    our_result :: integer(),
    our_result_bitcoin :: integer(),
    our_result_namecoin :: integer(),
    upstream_result :: integer(),
    reason :: binary() | undefined,
    source :: binary(),
    solution :: binary() | undefined,
    block_num :: binary() | undefined,
    prev_block_hash :: binary() | undefined,
    useragent :: string()
}).
-type sql_share() :: #sql_share{}.

% Internal state record
-record(state, {
    logger_id :: atom(),
    sql_config :: {Host :: string(), Port :: integer(), User :: string(), Pass :: string(), Database :: string()},
    sql_module :: module(),
    
    log_remote :: boolean(),
    subpool_id :: binary() | any,
    log_type :: main | aux | both,
    commit_interval :: integer(),
    always_log_data :: boolean(),
    conv_ts :: fun((erlang:timestamp()) -> calendar:datetime()),
    insert_stmt_head :: binary(),
    insert_field_ids :: [integer()],
    query_size_limit :: integer() | unlimited,
    
    sql_conn :: pid(),
    error_count = 0 :: integer(),
    commit_timer :: timer:tref() | undefined,
    
    sql_shares = [] :: [sql_share()]
}).

-define(MAX_ERROR_COUNT, 5).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init({LoggerId, SQLModule, Config}) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Load settings
    {DefaultPort, DefaultUser} = SQLModule:defaults(),
    Host = binary_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    Port = proplists:get_value(port, Config, DefaultPort),
    Database = binary_to_list(proplists:get_value(database, Config, <<"ecoinpool">>)),
    User = binary_to_list(proplists:get_value(user, Config, DefaultUser)),
    Pass = binary_to_list(ecoinpool_util:parse_json_password(proplists:get_value(pass, Config, <<"">>))),
    Table = proplists:get_value(table, Config, <<"shares">>),
    LogRemote = proplists:get_value(log_remote, Config, false),
    SubpoolId = proplists:get_value(subpool_id, Config, any),
    LogType = case proplists:get_value(log_type, Config, <<"main">>) of
        <<"aux">> -> aux;
        <<"both">> -> both;
        _ -> main
    end,
    CommitInterval = proplists:get_value(commit_interval, Config, 15),
    AlwaysLogData = proplists:get_value(always_log_data, Config, false),
    % Start SQL connection
    {ok, SQLConn} = SQLModule:connect(LoggerId, Host, Port, User, Pass, Database),
    % Check available columns
    FieldInfo = lists:zip(record_info(fields, sql_share), lists:seq(2, record_info(size, sql_share))),
    AvailableFieldNames = SQLModule:get_field_names(SQLConn, Table),
    {InsertFieldNames, InsertFieldIds} = lists:foldr(
        fun (N, {IFN, IFI}) ->
            case proplists:get_value(binary_to_atom(N, utf8), FieldInfo) of
                undefined -> {IFN, IFI};
                I -> {[binary_to_list(N) | IFN], [I | IFI]}
            end
        end,
        {[], []},
        AvailableFieldNames
    ),
    InsertStmtHead = iolist_to_binary(["INSERT INTO ", Table, " (", string:join(InsertFieldNames, ", "), ") VALUES\n"]),
    % Get the server's time difference to UTC and setup the timestamp converter
    ConvTS = make_timestamp_converter(SQLModule:get_timediff(SQLConn)),
    % Get the query size limit
    QuerySizeLimit = SQLModule:get_query_size_limit(SQLConn),
    % Setup commit timer
    CommitTimer = if
        not is_integer(CommitInterval); CommitInterval =< 0 ->
            undefined;
        true ->
            {ok, T} = timer:send_interval(CommitInterval * 1000, insert_sql_shares),
            T
    end,
    {ok, #state{
        logger_id = LoggerId,
        sql_config = {Host, Port, User, Pass, Database},
        sql_module = SQLModule,
        
        log_remote = LogRemote,
        subpool_id = SubpoolId,
        log_type = LogType,
        commit_interval = case CommitTimer of undefined -> 0; _ -> CommitInterval end,
        always_log_data = AlwaysLogData,
        conv_ts = ConvTS,
        insert_stmt_head = InsertStmtHead,
        insert_field_ids = InsertFieldIds,
        query_size_limit=QuerySizeLimit,
        
        sql_conn = SQLConn,
        commit_timer = CommitTimer
    }}.

handle_call(_, _From, State) ->
    {reply, error, State}.

handle_cast(#share{
        timestamp=Timestamp,
        server_id=ServerId,
        
        subpool_id=SubpoolId,
        subpool_name=SubpoolName,
        worker_name=WorkerName,
        user_id=UserId,
        ip=IP,
        user_agent=UserAgent,
        
        state=ShareState,
        reject_reason=RejectReason,
        hash=Hash,
        target=Target,
        block_num=BlockNum,
        prev_block=PrevBlock,
        data=Data,
        
        auxpool_name=AuxpoolName,
        aux_state=AuxState,
        aux_hash=AuxHash,
        aux_target=AuxTarget,
        aux_block_num=AuxBlockNum,
        aux_prev_block=AuxPrevBlock
    },
    State=#state{
        logger_id=LoggerId,
        log_remote=LogRemote,
        subpool_id=FilterSubpoolId,
        log_type=LogType,
        always_log_data = AlwaysLogData,
        conv_ts=ConvTS,
        commit_timer=CommitTimer,
        sql_shares=SQLShares
    }) when
        (ServerId =:= local) or LogRemote,
        (SubpoolId =:= FilterSubpoolId) or (FilterSubpoolId =:= any) ->
    
    Solution = if
        AlwaysLogData;
        ShareState =:= candidate, LogType =/= aux;
        AuxState =:= candidate, LogType =/= main ->
            conv_binary_data(Data);
        true ->
            undefined
    end,
    
    SQLShare = #sql_share{
        time = ConvTS(Timestamp),
        rem_host = IP,
        username = WorkerName,
        our_result_bitcoin = case ShareState of valid -> 1; candidate -> 1; _ -> 0 end,
        our_result_namecoin = case AuxState of valid -> 1; candidate -> 1; _ -> 0 end,
        reason = RejectReason,
        solution = Solution,
        useragent = UserAgent
    },
    
    SQLShare1 = if
        LogType =:= main;
        LogType =:= both ->
            BinBlockNum = conv_block_num(BlockNum),
            PrevBlockHash = conv_binary_data(PrevBlock),
            case LogType of
                both when AuxpoolName =/= undefined ->
                    BinAuxBlockNum = conv_block_num(AuxBlockNum),
                    SQLShare#sql_share{
                        our_result = SQLShare#sql_share.our_result_bitcoin,
                        upstream_result = if ShareState =:= candidate; AuxState =:= candidate -> 1; true -> 0 end,
                        source = <<SubpoolName/binary, "/", AuxpoolName/binary>>,
                        block_num = <<BinBlockNum/binary, "/", BinAuxBlockNum/binary>>,
                        prev_block_hash = PrevBlockHash,
                        reason = if ShareState =/= invalid, AuxState =:= invalid -> <<"partial-stale">>; true -> SQLShare#sql_share.reason end
                    };
                _ ->
                    SQLShare#sql_share{
                        our_result = SQLShare#sql_share.our_result_bitcoin,
                        upstream_result = case ShareState of candidate -> 1; _ -> 0 end,
                        source = SubpoolName,
                        block_num = BinBlockNum,
                        prev_block_hash = PrevBlockHash
                    }
            end;
        true ->
            SQLShare#sql_share{
                our_result = SQLShare#sql_share.our_result_namecoin,
                upstream_result = case AuxState of candidate -> 1; _ -> 0 end,
                source = AuxpoolName,
                block_num = conv_block_num(AuxBlockNum),
                prev_block_hash = conv_binary_data(AuxPrevBlock)
            }
    end,
    
    case CommitTimer of
        undefined ->
            #state{sql_module=SQLModule, sql_conn=SQLConn, insert_stmt_head=InsertStmtHead, insert_field_ids=InsertFieldIds} = State,
            case insert_sql_shares(LoggerId, SQLModule, SQLConn, [SQLShare1], InsertStmtHead, InsertFieldIds, unlimited) of
                {ok, []} ->
                    {noreply, State};
                {error, _} -> % Error handling: start a default commit timer
                    {ok, T} = timer:send_interval(15000, insert_sql_shares),
                    {noreply, State#state{sql_shares=[SQLShare1 | SQLShares], error_count=1, commit_timer=T}}
            end;
        _ ->
            {noreply, State#state{sql_shares=[SQLShare1 | SQLShares]}}
    end;

handle_cast(#share{}, State) -> % Ignore filtered shares
    {ok, State}.

handle_info(insert_sql_shares, State=#state{sql_shares=[]}) ->
    {noreply, State};
handle_info(insert_sql_shares, State=#state{
        logger_id=LoggerId,
        sql_config=SQLConfig,
        sql_module=SQLModule,
        commit_interval=CommitInterval,
        insert_stmt_head=InsertStmtHead,
        insert_field_ids=InsertFieldIds,
        query_size_limit=OldQuerySizeLimit,
        sql_conn=OldSQLConn,
        error_count=ErrorCount,
        commit_timer=CommitTimer,
        sql_shares=SQLShares}) ->
    
    flush_inserts(), % Reduce the amount of stress
    
    {SQLConn, QuerySizeLimit} = check_reconnect(OldSQLConn, OldQuerySizeLimit, LoggerId, SQLModule, SQLConfig),
    
    case insert_sql_shares(LoggerId, SQLModule, SQLConn, SQLShares, InsertStmtHead, InsertFieldIds, QuerySizeLimit) of
        {ok, RestSQLShares} ->
            if
                ErrorCount > 0 ->
                    log4erl:warn("Successfully recovered from previous errors, ~b shares saved (~p).", [length(SQLShares) - length(RestSQLShares), LoggerId]);
                true ->
                    ok
            end,
            NewCommitTimer = case RestSQLShares of
                [] ->
                    case CommitInterval of
                        0 -> % Stop default commit timer (started due to error handling)
                            timer:cancel(CommitTimer),
                            undefined;
                        _ ->
                            CommitTimer
                    end;
                _ ->
                    log4erl:warn("Could not send all shares at once due to size limit, continuing later (~p).", [LoggerId]),
                    CommitTimer
            end,
            {noreply, State#state{query_size_limit=QuerySizeLimit, sql_conn=SQLConn, error_count=0, commit_timer=NewCommitTimer, sql_shares=RestSQLShares}};
        {error, _} ->
            log4erl:warn("Cached shares (~p): ~b", [LoggerId, length(SQLShares)]),
            if
                ErrorCount + 1 > ?MAX_ERROR_COUNT,
                SQLConn =/= undefined ->
                    log4erl:warn("Maximum error count reached, reconnecting (~p).", [LoggerId]),
                    SQLModule:disconnect(SQLConn),
                    {noreply, State#state{query_size_limit=QuerySizeLimit, error_count=0, sql_conn=undefined}};
                true ->
                    {noreply, State#state{query_size_limit=QuerySizeLimit, error_count=ErrorCount+1, sql_conn=SQLConn}}
            end
    end;

handle_info({'EXIT', SQLConn, _Reason}, State=#state{sql_conn=SQLConn}) ->
    {noreply, State#state{sql_conn=undefined}};

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, State=#state{commit_timer=CommitTimer}) ->
    case CommitTimer of
        undefined ->
            ok;
        _ ->
            timer:cancel(CommitTimer),
            handle_info(insert_sql_shares, State) % Flush remaining shares
    end,
    ok.

code_change(_OldVsn, State=#state{logger_id=LoggerId, sql_config=SQLConfig, sql_module=SQLModule, query_size_limit=OldQuerySizeLimit, sql_conn=OldSQLConn}, _Extra) ->
    {SQLConn, QuerySizeLimit} = check_reconnect(OldSQLConn, OldQuerySizeLimit, LoggerId, SQLModule, SQLConfig),
    ConvTS = make_timestamp_converter(SQLModule:get_timediff(SQLConn)),
    {ok, State#state{query_size_limit=QuerySizeLimit, sql_conn=SQLConn, conv_ts=ConvTS}}.

%% ===================================================================
%% Other functions
%% ===================================================================

conv_binary_data(undefined) ->
    undefined;
conv_binary_data(Data) ->
    ecoinpool_util:bin_to_hexbin(Data).

conv_block_num(undefined) ->
    <<>>;
conv_block_num(BlockNum) ->
    list_to_binary(integer_to_list(BlockNum)).

make_timestamp_converter({0,0,0}) ->
    fun calendar:now_to_datetime/1;
make_timestamp_converter(TimeDiff) ->
    TimeDiffSeconds = calendar:time_to_seconds(TimeDiff),
    fun (Now) ->
        DateTime = calendar:now_to_datetime(Now),
        S = calendar:datetime_to_gregorian_seconds(DateTime),
        calendar:gregorian_seconds_to_datetime(S + TimeDiffSeconds)
    end.

-spec insert_sql_shares(LoggerId :: atom(), SQLModule :: module(), SQLConn :: pid(), SQLShares :: [sql_share()], InsertStmtHead :: binary(), InsertFieldIds :: [integer()], QuerySizeLimit :: integer() | unlimited) -> {ok, [sql_share()]} | {error, term()}.
insert_sql_shares(_, _, undefined, _, _, _, _) ->
    {error, no_connection};
insert_sql_shares(LoggerId, SQLModule, SQLConn, SQLShares, InsertStmtHead, InsertFieldIds, QuerySizeLimit) ->
    [FirstSQLShare | OtherSQLShares] = lists:reverse(SQLShares),
    InsertStmtFirstRow = iolist_to_binary(make_sql_share_row(SQLModule, FirstSQLShare, InsertFieldIds)),
    {InsertStmt, RestSQLShares} = make_sql_share_rows(SQLModule, OtherSQLShares, InsertFieldIds, QuerySizeLimit, <<InsertStmtHead/binary, InsertStmtFirstRow/binary>>),
    case SQLModule:fetch_result(SQLConn, InsertStmt) of
        {ok, _} -> {ok, RestSQLShares};
        {error, Error} -> log4erl:warn("Error while inserting shares (~p): ~p", [LoggerId, Error]), {error, Error}
    end.

-spec make_sql_share_rows(SQLModule :: module(), SQLShares :: [sql_share()], InsertFieldIds :: [integer()], QuerySizeLimit :: integer() | unlimited, AccStmt :: binary()) -> {binary(), [sql_share()]}.
make_sql_share_rows(_, [], _, _, AccStmt) ->
    {<<AccStmt/binary, ";">>, []};
make_sql_share_rows(SQLModule, [SQLShare | T], InsertFieldIds, QuerySizeLimit, AccStmt) ->
    Row = iolist_to_binary(make_sql_share_row(SQLModule, SQLShare, InsertFieldIds)),
    if
        QuerySizeLimit =:= unlimited;
        byte_size(AccStmt) + byte_size(Row) + 3 =< QuerySizeLimit ->
            make_sql_share_rows(SQLModule, T, InsertFieldIds, QuerySizeLimit, <<AccStmt/binary, ",\n", Row/binary>>);
        true ->
            {<<AccStmt/binary, ";">>, T}
    end.

-spec make_sql_share_row(SQLModule :: module(), SQLShare :: sql_share(), InsertFieldIds :: [integer()]) -> iolist().
make_sql_share_row(SQLModule, SQLShare, InsertFieldIds) ->
    EncodedElements = SQLModule:encode_elements([element(FieldId, SQLShare) || FieldId <- InsertFieldIds]),
    [$(, string:join(EncodedElements, ", "), $)].

check_reconnect(undefined, _, LoggerId, SQLModule, SQLConfig) ->
    {Host, Port, User, Pass, Database} = SQLConfig,
    case SQLModule:connect(LoggerId, Host, Port, User, Pass, Database) of
        {ok, SQLConn} ->
            QuerySizeLimit = SQLModule:get_query_size_limit(SQLConn),
            {SQLConn, QuerySizeLimit};
        {error, _} ->
            log4erl:warn("Reconnecting failed, trying again later (~p).", [LoggerId]),
            {undefined, undefined}
    end;
check_reconnect(SQLConn, QuerySizeLimit, _, _, _) ->
    {SQLConn, QuerySizeLimit}.

flush_inserts() ->
    receive
        insert_sql_shares -> flush_inserts()
    after
        0 -> ok
    end.
