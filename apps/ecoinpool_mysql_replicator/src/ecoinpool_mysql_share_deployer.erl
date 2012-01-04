
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

-module(ecoinpool_mysql_share_deployer).
-behaviour(gen_server).

-export([
    start_link/6,
    start_link/7
]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(db_state, {
    db,
    start_ref,
    changes_pid,
    seq
}).

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
    useragent :: binary(),
    
    main_seq :: integer(),
    aux_seq :: integer()
}).
-type my_share() :: #my_share{}.

-type main_q_entry() :: {WorkerId :: binary(), Hash :: binary(), Share :: my_share()}.
-type aux_q_entry() :: {WorkerId :: binary(), ParentHash :: binary(), Seq :: integer(), State :: invalid | valid | candidate, Solution :: binary() | undefined}.

% Internal state record
-record(state, {
    config_id :: binary(),
    state_file_name :: string(),
    
    worker_db_state :: #db_state{},
    main_db_state :: #db_state{},
    aux_db_state :: #db_state{} | undefined,
    aux_stored_seq :: integer(),
    
    worker_name_tbl :: ets:tid(),
    
    my_pool_id :: atom(),
    my_table :: string(),
    my_timer :: timer:tref() | undefined,
    
    main_q :: [main_q_entry()] | undefined,
    aux_q :: [aux_q_entry()] | undefined,
    my_shares = [] :: [my_share()],
    insert_stmt_head :: binary(),
    insert_field_ids :: [integer()]
}).

-define(Log(F, P), io:format("~p:~b: " ++ F ++ "~n", [?MODULE, ?LINE] ++ P)).

%% ===================================================================
%% API functions
%% ===================================================================

-spec start_link(ConfigIdStr :: string(), WorkerDb :: tuple(), MainPoolDb :: tuple(), MyPoolId :: atom(), MyTable :: string(), MyInterval :: integer()) -> {ok, pid()} | ignore | {error, {already_started, pid()} | term()}.
start_link(ConfigIdStr, WorkerDb, MainPoolDb, MyPoolId, MyTable, MyInterval) ->
    start_link(ConfigIdStr, WorkerDb, MainPoolDb, undefined, MyPoolId, MyTable, MyInterval).

-spec start_link(ConfigIdStr :: string(), WorkerDb :: tuple(), MainPoolDb :: tuple(), AuxPoolDb :: tuple() | undefined, MyPoolId :: atom(), MyTable :: string(), MyInterval :: integer()) -> {ok, pid()} | ignore | {error, {already_started, pid()} | term()}.
start_link(ConfigIdStr, WorkerDb, MainPoolDb, AuxPoolDb, MyPoolId, MyTable, MyInterval) ->
    gen_server:start_link(?MODULE, [ConfigIdStr, WorkerDb, MainPoolDb, AuxPoolDb, MyPoolId, MyTable, MyInterval], []).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([ConfigIdStr, WorkerDb, MainPoolDb, AuxPoolDb, MyPoolId, MyTable, MyInterval]) ->
    % Trap exit
    process_flag(trap_exit, true),
    WithAuxChain = case AuxPoolDb of undefined -> false; _ -> true end,
    ?Log("ecoinpool_mysql_share_deployer starting. ID: ~s; with aux db: ~p", [ConfigIdStr, WithAuxChain]),
    % Check available columns
    {data, MyFieldsResult} = mysql:fetch(MyPoolId, ["SHOW COLUMNS FROM `", MyTable, "`;"]),
    MyFieldNames = [FName || {FName, _, _, _, _, _} <- mysql:get_result_rows(MyFieldsResult)],
    {InsertFieldNames, InsertFieldIds} = lists:foldr(
        fun (N, {IFN, IFI}) ->
            I = case N of
                <<"time">> -> #my_share.time;
                <<"rem_host">> -> #my_share.rem_host;
                <<"username">> -> #my_share.username;
                <<"our_result">> -> #my_share.our_result;
                <<"our_result_bitcoin">> when WithAuxChain -> #my_share.our_result_bitcoin;
                <<"our_result_namecoin">> when WithAuxChain -> #my_share.our_result_namecoin;
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
    InsertStmtHead = iolist_to_binary(["INSERT INTO `", MyTable, "` (", string:join(InsertFieldNames, ", "), ") VALUES\n"]),
    % Load any stored sequence numbers
    StateFileName = ConfigIdStr ++ ".state",
    {MainPoolDbSeq, AuxPoolDbSeq} = case file:consult(StateFileName) of
        {ok, Terms} ->
            {proplists:get_value(main_seq, Terms, 0), proplists:get_value(aux_seq, Terms, 0)};
        {error, X} when is_atom(X) ->
            {0, 0}
    end,
    % Get the worker DB sequence number
    {ok, {WorkerDbInfo}} = couchbeam:db_info(WorkerDb),
    WorkerDbSeq = proplists:get_value(<<"update_seq">>, WorkerDbInfo),
    % Start monitors
    case start_change_monitor(WorkerDb, WorkerDbSeq) of
        {ok, WorkerDbState} ->
            case start_change_monitor(MainPoolDb, MainPoolDbSeq) of
                {ok, MainPoolDbState} ->
                    case start_change_monitor(AuxPoolDb, AuxPoolDbSeq) of
                        {ok, AuxPoolDbState} ->
                            % Start the timer
                            MyTimer = case MyInterval of
                                0 -> undefined;
                                _ -> {ok, T} = timer:send_interval(MyInterval * 1000, insert_my_shares), T
                            end,
                            WorkerNameTbl = ets:new(worker_name_tbl, [set, protected]),
                            {ok, #state{
                                config_id = list_to_binary(ConfigIdStr),
                                state_file_name = StateFileName,
                                worker_db_state = WorkerDbState,
                                main_db_state = MainPoolDbState,
                                aux_db_state = AuxPoolDbState,
                                aux_stored_seq = AuxPoolDbSeq,
                                worker_name_tbl = WorkerNameTbl,
                                my_pool_id = MyPoolId,
                                my_table = MyTable,
                                my_timer = MyTimer,
                                main_q = case AuxPoolDbState of undefined -> undefined; _ -> [] end,
                                aux_q = case AuxPoolDbState of undefined -> undefined; _ -> [] end,
                                insert_stmt_head = InsertStmtHead,
                                insert_field_ids = InsertFieldIds
                            }};
                        {error, Error} ->
                            stop_change_monitor(MainPoolDbState),
                            stop_change_monitor(WorkerDbState),
                            {stop, Error}
                    end;
                {error, Error} ->
                    stop_change_monitor(WorkerDbState),
                    {stop, Error}
            end;
        {error, Error} ->
            {stop, Error}
    end.

handle_call(_Message, _From, State) ->
    {reply, {error, no_such_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({change, StartRef, {RowProps}}, State=#state{config_id=ConfigId, worker_db_state=WorkerDbState, main_db_state=MainPoolDbState, aux_db_state=AuxPoolDbState, aux_stored_seq=AuxStoredSeq, worker_name_tbl=WorkerNameTbl, my_timer=MyTimer, main_q=MainQ, aux_q=AuxQ, my_shares=MyShares}) ->
    Id = proplists:get_value(<<"id">>, RowProps),
    Deleted = proplists:get_value(<<"deleted">>, RowProps, false),
    Seq = proplists:get_value(<<"seq">>, RowProps),
    {DocProps} = proplists:get_value(<<"doc">>, RowProps),
    case WorkerDbState of
        #db_state{start_ref=StartRef} ->
            case ets:member(WorkerNameTbl, Id) of
                true ->
                    if
                        Deleted -> ets:delete(WorkerNameTbl, Id);
                        true -> ets:insert(WorkerNameTbl, {Id, proplists:get_value(<<"name">>, DocProps, Id)})
                    end;
                false ->
                    ok
            end,
            {noreply, State#state{worker_db_state=WorkerDbState#db_state{seq=Seq}}};
        _ ->
            DesignDocument = case Id of <<"_design/", _/binary>> -> true; _ -> false end,
            if
                Deleted; DesignDocument -> % Always ignore deleted shares and design documents
                    {noreply, State};
                true ->
                    case MainPoolDbState of
                        #db_state{start_ref=StartRef} ->
                            {NewMainQ, NewAuxQ, NewMyShares} = handle_main_share(DocProps, Seq, MainQ, AuxQ, MyShares, WorkerNameTbl, WorkerDbState#db_state.db, AuxStoredSeq, ConfigId),
                            NewState = case NewMyShares of
                                [] ->
                                    State#state{main_q=NewMainQ, aux_q=NewAuxQ, my_shares=NewMyShares};
                                [#my_share{aux_seq=NewAuxStoredSeq} | _] ->
                                    State#state{aux_stored_seq=NewAuxStoredSeq, main_q=NewMainQ, aux_q=NewAuxQ, my_shares=NewMyShares}
                            end,
                            case MyTimer of
                                undefined -> handle_info(insert_my_shares, NewState);
                                _ -> {noreply, NewState}
                            end;
                        _ ->
                            case AuxPoolDbState of
                                #db_state{start_ref=StartRef} ->
                                    {NewMainQ, NewAuxQ, NewMyShares} = handle_aux_share(DocProps, Seq, MainQ, AuxQ, MyShares),
                                    NewState = State#state{main_q=NewMainQ, aux_q=NewAuxQ, my_shares=NewMyShares},
                                    case MyTimer of
                                        undefined -> handle_info(insert_my_shares, NewState);
                                        _ -> {noreply, NewState}
                                    end;
                                _ ->
                                    {stop, unknown_change_received, State}
                            end
                    end
            end
    end;

handle_info(insert_my_shares, State=#state{my_shares=[]}) ->
    {noreply, State};
handle_info(insert_my_shares, State=#state{state_file_name=StateFileName, my_shares=MyShares, my_pool_id=MyPoolId, insert_stmt_head=InsertStmtHead, insert_field_ids=InsertFieldIds}) ->
    [#my_share{main_seq=MainPoolDbSeq, aux_seq=AuxPoolDbSeq} | _] = MyShares,
    insert_my_shares(MyPoolId, lists:reverse(MyShares), InsertStmtHead, InsertFieldIds),
    write_state_file(StateFileName, MainPoolDbSeq, AuxPoolDbSeq),
    {noreply, State#state{my_shares=[]}};

handle_info({'DOWN', _, process, Pid, _}, State=#state{worker_db_state=WorkerDbState, main_db_state=MainPoolDbState, aux_db_state=AuxPoolDbState}) ->
    case WorkerDbState of
        #db_state{changes_pid=Pid} ->
            case restart_change_monitor(WorkerDbState) of
                {ok, NewWorkerDbState} ->
                    {noreply, State#state{worker_db_state=NewWorkerDbState}};
                {error, Reason} ->
                    {stop, Reason, State#state{worker_db_state=undefined}}
            end;
        _ ->
            case MainPoolDbState of
                #db_state{changes_pid=Pid} ->
                    case restart_change_monitor(MainPoolDbState) of
                        {ok, NewMainPoolDbState} ->
                            {noreply, State#state{main_db_state=NewMainPoolDbState}};
                        {error, Reason} ->
                            {stop, Reason, State#state{main_db_state=undefined}}
                    end;
                _ ->
                    case AuxPoolDbState of
                        #db_state{changes_pid=Pid} ->
                            case restart_change_monitor(AuxPoolDbState) of
                                {ok, NewAuxPoolDbState} ->
                                    {noreply, State#state{aux_db_state=NewAuxPoolDbState}};
                                {error, Reason} ->
                                    {stop, Reason, State#state{aux_db_state=undefined}}
                            end;
                        _ ->
                            {stop, unknown_process_died, State}
                    end
            end
    end;

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{worker_db_state=WorkerDbState, main_db_state=MainPoolDbState, aux_db_state=AuxPoolDbState, my_timer=MyTimer}) ->
    stop_change_monitor(WorkerDbState),
    stop_change_monitor(MainPoolDbState),
    stop_change_monitor(AuxPoolDbState),
    case MyTimer of
        undefined -> ok;
        _ -> timer:cancel(MyTimer)
    end,
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.


handle_main_share(DocProps, Seq, MainQ, AuxQ, MyShares, WorkerNameTbl, WorkerDb, AuxStoredSeq, ConfigId) ->
    [YR,MH,DY,HR,ME,SD] = proplists:get_value(<<"timestamp">>, DocProps),
    WorkerId = proplists:get_value(<<"worker_id">>, DocProps),
    Username = lookup_worker_name(WorkerId, WorkerNameTbl, WorkerDb),
    ShareState = get_share_state(DocProps),
    OurResult = case ShareState of invalid -> 0; _ -> 1 end,
    Solution = case proplists:get_value(<<"data">>, DocProps) of
        undefined -> undefined;
        Data -> string_to_hexbin(base64:decode_to_string(Data))
    end,
    BlockNum = case proplists:get_value(<<"block_num">>, DocProps) of
        undefined -> undefined;
        IntBlockNum -> list_to_binary(integer_to_list(IntBlockNum))
    end,
    RejectReason = proplists:get_value(<<"reject_reason">>, DocProps),
    S = #my_share{
        time = {{YR,MH,DY}, {HR,ME,SD}},
        rem_host = proplists:get_value(<<"ip">>, DocProps),
        username = Username,
        our_result = OurResult,
        our_result_bitcoin = OurResult,
        upstream_result = case ShareState of candidate -> 1; _ -> 0 end,
        reason = RejectReason,
        source = ConfigId,
        solution = Solution,
        block_num = BlockNum,
        prev_block_hash = proplists:get_value(<<"prev_block">>, DocProps),
        useragent = proplists:get_value(<<"user_agent">>, DocProps),
        main_seq = Seq,
        aux_seq = AuxStoredSeq
    },
    case proplists:get_value(<<"hash">>, DocProps) of
        Hash when is_binary(Hash), is_list(MainQ), is_list(AuxQ) ->
            check_share_queues(MainQ ++ [{WorkerId, Hash, S}], AuxQ, MyShares);
        _ ->
            {MainQ, AuxQ, [S | MyShares]}
    end.

handle_aux_share(DocProps, Seq, MainQ, AuxQ, MyShares) ->
    case proplists:get_value(<<"parent_hash">>, DocProps) of
        ParentHash when is_binary(ParentHash), is_list(MainQ), is_list(AuxQ) ->
            Solution = case proplists:get_value(<<"data">>, DocProps) of
                undefined -> undefined;
                Data -> string_to_hexbin(base64:decode_to_string(Data))
            end,
            check_share_queues(MainQ, AuxQ ++ [{proplists:get_value(<<"worker_id">>, DocProps), ParentHash, Seq, get_share_state(DocProps), Solution}], MyShares);
        undefined ->
            {MainQ, AuxQ, MyShares}
    end.

-spec check_share_queues(MainQ :: [main_q_entry()], AuxQ :: [aux_q_entry()], MyShares :: [my_share()]) -> {[main_q_entry()], [aux_q_entry()], [my_share()]}.
check_share_queues(MainQ=[], AuxQ, MyShares) ->
    {MainQ, AuxQ, MyShares};
check_share_queues(MainQ, AuxQ=[], MyShares) ->
    {MainQ, AuxQ, MyShares};
check_share_queues(MainQ=[{WorkerId, Hash, S} | MainQT], AuxQ, MyShares) ->
    CleanedAuxQ = lists:dropwhile(
        fun ({AuxWorkerId, ParentHash, _, _, _}) ->
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
                        fun ({AuxWorkerId, ParentHash, _, _, _}) ->
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
                    ?Log("Detected a stale main share!", []),
                    check_share_queues(MainQT, AuxQ, [S | MyShares])
            end;
        [{WorkerId, Hash, AuxSeq, AuxState, AuxSolution} | AuxQT] ->
            if
                length(AuxQT) < length(AuxQ) - 1 ->
                    ?Log("Dropped ~b non-correlating aux share(s).", [length(AuxQ) - 1 - length(AuxQT)]);
                true ->
                    ok
            end,
            FullS = case AuxState of
                candidate ->
                    S#my_share{our_result_namecoin=1, upstream_result=1, solution=AuxSolution, aux_seq=AuxSeq};
                valid ->
                    S#my_share{our_result_namecoin=1, aux_seq=AuxSeq};
                invalid ->
                    S#my_share{aux_seq=AuxSeq}
            end,
            check_share_queues(MainQT, AuxQT, [FullS | MyShares])
    end.


restart_change_monitor(#db_state{db=DB, seq=Since}) ->
    start_change_monitor(DB, Since).

start_change_monitor(undefined, _) ->
    {ok, undefined};
start_change_monitor(DB, Since) ->
    case couchbeam_changes:stream(DB, self(), [continuous, heartbeat, include_docs, {since, Since}]) of
        {ok, StartRef, ChangesPid} ->
            erlang:monitor(process, ChangesPid),
            unlink(ChangesPid),
            {ok, #db_state{db=DB, start_ref=StartRef, changes_pid=ChangesPid, seq=Since}};
        Error ->
            Error
    end.

stop_change_monitor(undefined) ->
    ok;
stop_change_monitor(#db_state{changes_pid=ChangesPid}) ->
    catch exit(ChangesPid, normal),
    ok.

-spec insert_my_shares(MyPoolId :: atom(), MyShares :: [my_share()], InsertStmtHead :: binary(), InsertFieldIds :: [integer()]) -> ok | {error, term()}.
insert_my_shares(MyPoolId, MyShares, InsertStmtHead, InsertFieldIds) ->
    FullStmt = [InsertStmtHead, string:join([make_my_share_row(MyShare, InsertFieldIds) || MyShare <- MyShares], ",\n"), $;],
    case mysql:fetch(MyPoolId, FullStmt) of
        {updated, _} -> ok;
        {error, Error} -> ?Log("Error while inserting shares: ~p", [Error]), {error, Error}
    end.

-spec make_my_share_row(MyShare :: my_share(), InsertFieldIds :: [integer()]) -> iolist().
make_my_share_row(MyShare, InsertFieldIds) ->
    Data = [mysql:encode(element(FieldId, MyShare)) || FieldId <- InsertFieldIds],
    [$(, string:join(Data, ", "), $)].

-spec write_state_file(StateFileName :: string(), MainPoolDbSeq :: integer(), AuxPoolDbSeq :: integer()) -> ok | {error, term()}.
write_state_file(StateFileName, MainPoolDbSeq, AuxPoolDbSeq) ->
    if
        MainPoolDbSeq > 0 ->
            MainData = [io_lib:write({main_seq, MainPoolDbSeq}), "."],
            WriteData = if
                AuxPoolDbSeq > 0 ->
                    [MainData, 10, io_lib:write({aux_seq, AuxPoolDbSeq}), "."];
                true ->
                    MainData
            end,
            file:write_file(StateFileName, WriteData);
        true ->
            file:delete(StateFileName)
    end.

lookup_worker_name(WorkerId, WorkerNameTbl, WorkerDb) ->
    case ets:lookup(WorkerNameTbl, WorkerId) of
        [{_, WorkerName}] ->
            WorkerName;
        [] ->
            WorkerName = case couchbeam:open_doc(WorkerDb, WorkerId) of
                {ok, {DocProps}} ->
                    proplists:get_value(<<"name">>, DocProps, WorkerId);
                _ ->
                    WorkerId
            end,
            ets:insert(WorkerNameTbl, {WorkerId, WorkerName}),
            WorkerName
    end.

get_share_state(DocProps) ->
    case proplists:get_value(<<"state">>, DocProps) of
        <<"valid">> -> valid;
        <<"candidate">> -> candidate;
        _ -> invalid
    end.

-spec string_to_hexbin(Str :: string()) -> binary().
string_to_hexbin(Str) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [X]) || X <- Str]).
