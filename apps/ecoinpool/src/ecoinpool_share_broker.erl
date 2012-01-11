
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

-module(ecoinpool_share_broker).
-behaviour(gen_event).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").
-include("ecoinpool_workunit.hrl").

-export([
    start_link/0,
    
    new_polling_monitor/1,
    new_polling_monitor/2,
    new_polling_monitor/3,
    new_polling_monitor/4,
    poll_for_changes/2,
    
    notify_share/1,
    notify_share/6,
    notify_invalid_share/4,
    notify_invalid_share/5,
    notify_invalid_share/6
]).

% Callbacks from gen_event
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-define(POLLING_MONITOR_TIMEOUT, 60 * 1000000).
-define(POLLING_MONITOR_TIMEOUT_CHECK, 10 * 1000).

-record(polling_monitor, {
    type :: subpool | user | worker,
    subpool_id :: binary(),
    is_aux = false :: boolean(),
    user_worker_id :: term(),
    last_return :: erlang:timestamp(),
    waiting :: {pid() | atom(), reference()} | undefined,
    has_changes = false :: boolean()
}).

-record(state, {
    pmon_tbl :: ets:tid(),
    pmons :: dict()
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    case gen_event:start_link({local, ?MODULE}) of
        {ok, Pid} ->
            gen_event:add_handler(Pid, ?MODULE, []),
            {ok, Pid};
        {error, Error} ->
            {error, Error}
    end.

% Returns a token (hex binary)
new_polling_monitor(SubpoolId) ->
    new_polling_monitor(SubpoolId, false).

new_polling_monitor(SubpoolId, Aux) ->
    gen_event:call(?MODULE, ?MODULE, {new_polling_monitor, subpool, Aux, SubpoolId, undefined}).

new_polling_monitor(SubpoolId, Type, UserId) ->
    new_polling_monitor(SubpoolId, false, Type, UserId).
   
new_polling_monitor(SubpoolId, Aux, user, UserId) ->
    gen_event:call(?MODULE, ?MODULE, {new_polling_monitor, user, Aux, SubpoolId, UserId});
new_polling_monitor(SubpoolId, Aux, worker, WorkerId) ->
    gen_event:call(?MODULE, ?MODULE, {new_polling_monitor, worker, Aux, SubpoolId, WorkerId}).

% Will reply by sending (tbd) to the given process
-spec poll_for_changes(To :: pid() | atom(), Token :: binary()) -> ok.
poll_for_changes(To, Token) ->
    ?MODULE ! {poll_for_changes, To, Token},
    ok.

-spec notify_share(Share :: share()) -> ok.
notify_share(Share=#share{}) ->
    gen_event:notify(?MODULE, Share).

-spec notify_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Workunit :: workunit(), Hash :: binary(), Candidates :: [candidate()]) -> ok.
notify_share(#subpool{id=SubpoolId, name=SubpoolName, round=Round, aux_pool=Auxpool},
            Peer,
            #worker{id=WorkerId, user_id=UserId, name=WorkerName},
            #workunit{target=Target, block_num=BlockNum, prev_block=PrevBlock, data=BData, aux_work=AuxWork, aux_work_stale=AuxWorkStale},
            Hash,
            Candidates) ->
    % This code will change if multi aux chains are supported
    Timestamp = erlang:now(),
    {MainState, AuxState} = lists:foldl(
        fun
            (main, {_, AS}) -> {candidate, AS};
            (aux, {MS, _}) -> {MS, candidate};
            (_, Acc) -> Acc
        end,
        {valid, valid},
        Candidates
    ),
    case Auxpool of
        #auxpool{name=AuxpoolName, round=AuxRound} when AuxWork =/= undefined ->
            if
                AuxWorkStale ->
                    notify_share(#share{
                        subpool_id = SubpoolId,
                        is_aux = true,
                        pool_name = AuxpoolName,
                        worker_id = WorkerId,
                        worker_name = WorkerName,
                        user_id = UserId,
                        peer = Peer,
                        timestamp = Timestamp,
                        
                        state = invalid,
                        reject_reason = stale,
                        parent_hash = Hash,
                        round = AuxRound
                    });
                true ->
                    #auxwork{aux_hash=AuxHash, target=AuxTarget, block_num=AuxBlockNum, prev_block=AuxPrevBlock} = AuxWork,
                    notify_share(#share{
                        subpool_id = SubpoolId,
                        is_aux = true,
                        pool_name = AuxpoolName,
                        worker_id = WorkerId,
                        worker_name = WorkerName,
                        user_id = UserId,
                        peer = Peer,
                        timestamp = Timestamp,
                        
                        state = AuxState,
                        hash = AuxHash,
                        parent_hash = Hash,
                        target = AuxTarget,
                        block_num = AuxBlockNum,
                        prev_block = AuxPrevBlock,
                        round = AuxRound,
                        data = BData
                    })
            end;
        _ ->
            ok
    end,
    
    notify_share(#share{
        subpool_id = SubpoolId,
        pool_name = SubpoolName,
        worker_id = WorkerId,
        worker_name = WorkerName,
        user_id = UserId,
        peer = Peer,
        timestamp = Timestamp,
        
        state = MainState,
        hash = Hash,
        target = Target,
        block_num = BlockNum,
        prev_block = PrevBlock,
        round = Round,
        data = BData
    }).

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Reason :: reject_reason()) -> ok.
notify_invalid_share(Subpool, Peer, Worker, Reason) ->
    notify_invalid_share(Subpool, Peer, Worker, undefined, undefined, Reason).

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Hash :: binary(), Reason :: reject_reason()) -> ok.
notify_invalid_share(Subpool, Peer, Worker, Hash, Reason) ->
    notify_invalid_share(Subpool, Peer, Worker, undefined, Hash, Reason).

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Workunit :: workunit() | undefined, Hash :: binary() | undefined, Reason :: reject_reason()) -> ok.
notify_invalid_share(#subpool{id=SubpoolId, name=SubpoolName, round=Round, aux_pool=Auxpool}, Peer, #worker{id=WorkerId, user_id=UserId, name=WorkerName}, Workunit, Hash, Reason) ->
    % This code will change if multi aux chains are supported
    Timestamp = erlang:now(),
    case Auxpool of
        #auxpool{name=AuxpoolName, round=AuxRound} ->
            case Workunit of
                #workunit{aux_work=#auxwork{aux_hash=AuxHash, target=AuxTarget, block_num=AuxBlockNum, prev_block=AuxPrevBlock}} ->
                    notify_share(#share{
                        subpool_id = SubpoolId,
                        is_aux = true,
                        pool_name = AuxpoolName,
                        worker_id = WorkerId,
                        worker_name = WorkerName,
                        user_id = UserId,
                        peer = Peer,
                        timestamp = Timestamp,
                        
                        state = invalid,
                        reject_reason = Reason,
                        hash = AuxHash,
                        parent_hash = Hash,
                        target = AuxTarget,
                        block_num = AuxBlockNum,
                        prev_block = AuxPrevBlock,
                        round = AuxRound
                    });
                _ ->
                    notify_share(#share{
                        subpool_id = SubpoolId,
                        is_aux = true,
                        pool_name = AuxpoolName,
                        worker_id = WorkerId,
                        worker_name = WorkerName,
                        user_id = UserId,
                        peer = Peer,
                        timestamp = Timestamp,
                        
                        state = invalid,
                        reject_reason = Reason,
                        parent_hash = Hash,
                        round = AuxRound
                    })
            end;
        _ ->
            ok
    end,
    
    case Workunit of
        #workunit{target=Target, block_num=BlockNum, prev_block=PrevBlock} ->
            notify_share(#share{
                subpool_id = SubpoolId,
                pool_name = SubpoolName,
                worker_id = WorkerId,
                worker_name = WorkerName,
                user_id = UserId,
                peer = Peer,
                timestamp = Timestamp,
                
                state = invalid,
                reject_reason = Reason,
                hash = Hash,
                target = Target,
                block_num = BlockNum,
                prev_block = PrevBlock,
                round = Round
            });
        _ ->
            notify_share(#share{
                subpool_id = SubpoolId,
                pool_name = SubpoolName,
                worker_id = WorkerId,
                worker_name = WorkerName,
                user_id = UserId,
                peer = Peer,
                timestamp = Timestamp,
                
                state = invalid,
                reject_reason = Reason,
                hash = Hash,
                round = Round
            })
    end.

%% ===================================================================
%% Gen_Event callbacks
%% ===================================================================

init([]) ->
    PMonTbl = ets:new(pmon_tbl, [set, protected]),
    {ok, _} = timer:send_interval(?POLLING_MONITOR_TIMEOUT_CHECK, timeout_check),
    {ok, #state{pmon_tbl=PMonTbl, pmons=dict:new()}}.

handle_event(#share{subpool_id=SubpoolId, is_aux=IsAux, worker_id=WorkerId, user_id=UserId, state=State}, State=#state{pmon_tbl=PMonTbl, pmons=PMons}) ->
    Pos = case State of invalid -> 2; valid -> 3; candidate -> 4 end,
    NewPMons = dict:map(
        fun
            (Token, PM=#polling_monitor{type=Type, subpool_id=ThisSubpoolId, is_aux=ThisAux, user_worker_id=UserOrWorkerId, waiting=Waiting, has_changes=HasChanges}) when ThisSubpoolId =:= SubpoolId, ThisAux =:= IsAux ->
                Key = case Type of
                    subpool ->
                        Token;
                    user when UserId =:= UserOrWorkerId ->
                        {Token, WorkerId};
                    worker when WorkerId =:= UserOrWorkerId ->
                        Token;
                    _ ->
                        undefined
                end,
                case Key of
                    undefined ->
                        PM;
                    _ ->
                        case ets:member(PMonTbl, Key) of
                            true ->
                                ets:update_counter(PMonTbl, Key, {Pos, 1});
                            _ ->
                                ets:insert(PMonTbl, setelement(Pos, {Key, 0,0,0}, 1))
                        end,
                        case Waiting of
                            undefined ->
                                if
                                    HasChanges ->
                                        PM;
                                    true ->
                                        PM#polling_monitor{has_changes=true}
                                end;
                            {To, MRef} ->
                                send_reply_and_flush(Token, Type, To, PMonTbl),
                                erlang:demonitor(MRef, [flush]),
                                PM#polling_monitor{last_return=erlang:now(), waiting=undefined}
                        end
                end;
            (_, PM) ->
                PM
        end,
        PMons
    ),
    {ok, State#state{pmons=NewPMons}}.

handle_call({new_polling_monitor, Type, Aux, SubpoolId, UserOrWorkerId}, State=#state{pmons=PMons}) ->
    Token = ecoinpool_util:new_random_uuid(),
    PMon = #polling_monitor{
        type=Type,
        subpool_id=SubpoolId,
        is_aux=Aux,
        user_worker_id=UserOrWorkerId,
        last_return=erlang:now()
    },
    {ok, Token, State#state{pmons=dict:store(Token, PMon, PMons)}}.

handle_info({poll_for_changes, To, Token}, State=#state{pmon_tbl=PMonTbl, pmons=PMons}) ->
    NewPMons = case dict:find(Token, PMons) of
        {ok, PM=#polling_monitor{type=Type, waiting=Waiting, has_changes=HasChanges}} ->
            if
                HasChanges ->
                    send_reply_and_flush(Token, Type, To, PMonTbl),
                    dict:store(Token, PM#polling_monitor{last_return=erlang:now(), has_changes=false}, PMons);
                true -> % Set to wait
                    case Waiting of
                        undefined ->
                            ok;
                        {To, MRef} ->
                            Waiting ! {share_changes_result, {error, kicked}}, % Kick out already waiting
                            erlang:demonitor(MRef, [flush])
                    end,
                    dict:store(Token, PM#polling_monitor{waiting={To, erlang:monitor(process, To)}}, PMons)
            end;
        error ->
            To ! {share_changes_result, {error, invalid_token}}, % Reply invalid token
            PMons
    end,
    {ok, State#state{pmons=NewPMons}};

handle_info(timeout_check, State=#state{pmons=PMons}) ->
    Now = erlang:now(),
    NewPMons = dict:filter(
        fun
            (_, #polling_monitor{last_return=LastReturn, waiting=undefined}) ->
                case timer:now_diff(Now, LastReturn) of
                    Diff when Diff > ?POLLING_MONITOR_TIMEOUT ->
                        false;
                    _ ->
                        true
                end;
            (_, _) ->
                true
        end,
        PMons
    ),
    {ok, State#state{pmons=NewPMons}};

handle_info({'DOWN', _, _, To, _}, State=#state{pmons=PMons}) ->
    NewPMons = dict:map(
        fun
            (_, PM=#polling_monitor{waiting={ThisTo, _}}) when ThisTo =:= To -> PM#polling_monitor{last_return=erlang:now(), waiting=undefined};
            (_, V) -> V
        end,
        PMons
    ),
    {ok, State#state{pmons=NewPMons}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

send_reply_and_flush(Token, user, To, PMonTbl) ->
    Data = [{WorkerId, Invalid, Valid, Candidate} || [WorkerId, Invalid, Valid, Candidate] <- ets:match(PMonTbl, {{Token, '$1'}, '$2', '$3', '$4'})],
    To ! {share_changes_result, {ok, Data}},
    do_flush(Token, user, PMonTbl);
send_reply_and_flush(Token, Type, To, PMonTbl) -> % Type can here be either subpool or worker
    Data = case ets:lookup(PMonTbl, Token) of
        [{_, Invalid, Valid, Candidate}] -> {Invalid, Valid, Candidate}
    end,
    To ! {share_changes_result, {ok, Data}},
    do_flush(Token, Type, PMonTbl).

do_flush(Token, user, PMonTbl) ->
    ets:match_delete(PMonTbl, {{Token, '_'}, '_', '_', '_'});
do_flush(Token, _, PMonTbl) -> % Type can here be either subpool or worker
    ets:delete(PMonTbl, Token).
