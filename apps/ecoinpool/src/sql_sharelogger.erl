
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
    sql_module :: module(),
    sql_conn :: pid(),
    log_remote :: boolean(),
    subpool_id :: binary() | any,
    log_type :: main | aux | both,
    commit_timer :: timer:tref() | undefined,
    always_log_data :: boolean(),
    
    sql_shares = [] :: [sql_share()],
    conv_ts :: fun((erlang:timestamp()) -> calendar:datetime()),
    insert_stmt_head :: binary(),
    insert_field_ids :: [integer()]
}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init({LoggerId, SQLModule, Config}) ->
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
    % Setup commit timer
    CommitTimer = if
        not is_integer(CommitInterval); CommitInterval =< 0 ->
            undefined;
        true ->
            {ok, T} = timer:send_interval(CommitInterval * 1000, insert_sql_shares),
            T
    end,
    {ok, #state{
        sql_module = SQLModule,
        sql_conn = SQLConn,
        log_remote = LogRemote,
        subpool_id = SubpoolId,
        log_type = LogType,
        commit_timer = CommitTimer,
        always_log_data = AlwaysLogData,
        conv_ts = ConvTS,
        insert_stmt_head = InsertStmtHead,
        insert_field_ids = InsertFieldIds
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
        log_remote=LogRemote,
        subpool_id=FilterSubpoolId,
        log_type=LogType,
        commit_timer=CommitTimer,
        always_log_data = AlwaysLogData,
        sql_shares=SQLShares,
        conv_ts=ConvTS
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
            insert_sql_shares(SQLModule, SQLConn, [SQLShare1], InsertStmtHead, InsertFieldIds),
            {noreply, State};
        _ ->
            {noreply, State#state{sql_shares=[SQLShare1 | SQLShares]}}
    end;

handle_cast(#share{}, State) -> % Ignore filtered shares
    {ok, State}.

handle_info(insert_sql_shares, State=#state{sql_shares=[]}) ->
    {noreply, State};
handle_info(insert_sql_shares, State=#state{sql_module=SQLModule, sql_conn=SQLConn, sql_shares=SQLShares, insert_stmt_head=InsertStmtHead, insert_field_ids=InsertFieldIds}) ->
    insert_sql_shares(SQLModule, SQLConn, lists:reverse(SQLShares), InsertStmtHead, InsertFieldIds),
    {noreply, State#state{sql_shares=[]}};

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

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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

-spec insert_sql_shares(SQLModule :: module(), SQLConn :: pid(), SQLShares :: [sql_share()], InsertStmtHead :: binary(), InsertFieldIds :: [integer()]) -> ok | {error, term()}.
insert_sql_shares(SQLModule, SQLConn, SQLShares, InsertStmtHead, InsertFieldIds) ->
    FullStmt = [InsertStmtHead, string:join([make_sql_share_row(SQLModule, SQLShare, InsertFieldIds) || SQLShare <- SQLShares], ",\n"), $;],
    case SQLModule:fetch_result(SQLConn, FullStmt) of
        {ok, _} -> ok;
        {error, Error} -> log4erl:warn("Error while inserting shares: ~p", [Error]), {error, Error}
    end.

-spec make_sql_share_row(SQLModule :: module(), SQLShare :: sql_share(), InsertFieldIds :: [integer()]) -> iolist().
make_sql_share_row(SQLModule, SQLShare, InsertFieldIds) ->
    EncodedElements = SQLModule:encode_elements([element(FieldId, SQLShare) || FieldId <- InsertFieldIds]),
    [$(, string:join(EncodedElements, ", "), $)].
